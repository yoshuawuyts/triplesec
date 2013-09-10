## This file is taken from the Stanford JavaScript Crypto Library
##    -> http://crypto.stanford.edu/sjcl/
##    -> filename : core/random/js
##
## @fileOverview Random number generator.
## 
##  @author Emily Stark
##  @author Mike Hamburg
##  @author Dan Boneh
##
## * @constructor
##  @class Random number generator
## 
##  @description
##  <p>
##  This random number generator is a derivative of Ferguson and Schneier's
##  generator Fortuna.  It collects entropy from various events into several
##  pools, implemented by streaming SHA-256 instances.  It differs from
##  ordinary Fortuna in a few ways, though.
##  </p>
## 
##  <p>
##  Most importantly, it has an entropy estimator.  This is present because
##  there is a strong conflict here between making the generator available
##  as soon as possible, and making sure that it doesn't "run on empty".
##  In Fortuna, there is a saved state file, and the system is likely to have
##  time to warm up.
##  </p>
## 
##  <p>
##  Second, because users are unlikely to stay on the page for very long,
##  and to speed startup time, the number of pools increases logarithmically:
##  a new pool is created when the previous one is actually used for a reseed.
##  This gives the same asymptotic guarantees as Fortuna, but gives more
##  entropy to early reseeds.
##  </p>
## 
##  <p>
##  The entire mechanism here feels pretty klunky.  Furthermore, there are
##  several improvements that should be made, including support for
##  dedicated cryptographic functions that may be present in some browsers;
##  state files in local storage; cookies containing randomness; etc.  So
##  look for improvements in future versions.
##  </p>
## 

{SHA512} = require './sha512'
{AES} = require './aes'

#======================================================================

exports.Prng = class Prng
 
  # Constants
  _NOT_READY               = 0
  _READY                   = 1
  _REQUIRES_RESEED         = 2

  constructor : (defaultParanoia) ->
    #
    @_pools                   = [ new SHA512() ]
    @_poolEntropy             = [0]
    @_reseedCount             = 0
    @_robins                  = {}
    @_eventId                 = 
    
    @_collectorIds            = {}
    @_collectorIdNext         = 0
    @_strength                = 0
    @_poolStrength            = 0
    @_nextReseed              = 0
    @_key                     = [0,0,0,0,0,0,0,0]
    @_counter                 = [0,0,0,0]
    @_cipher                  = undefined
    @_defaultParanoia         = defaultParanoia

    # Event Listener Stuff
    @_collectorsStarted       = false
    @_callbacks               = {progress: {}, seeded: {}}
    @_callbackI               = 0
    

    @_MAX_WORDS_PER_BURST     = 65536
    @_PARANOIA_LEVELS         = [0,48,64,96,128,192,256,384,512,768,1024]
    @_MILLISECONDS_PER_RESEED = 30000
    @_BITS_PER_RESEED         = 80
 
  # Generate several random words, and return them in an array
  # @param {Number} nwords The number of words to generate.
  # 
  randomWords : (nwords, paranoia) ->
    out = []
    readiness = @isReady paranoia

    if readiness is @_NOT_READY
      throw new Exception "generator isn't seeded"
    else if (readiness & @_REQUIRES_RESEED)
      @_reseedFromPools (not (readiness & @_READY))

    for i in [0...nwords] by 4
      @_gate() unless ((i+1) % @_MAX_WORDS_PER_BURST)
      g = @_gen4words();
      out.push g[0],g[1],g[2],g[3]
    @_gate()
    out[0...nwords] 

  setDefaultParanoia : (paranoia) -> @_defaultParanoia = paranoia
  
  #
  # Add entropy to the pools.
  # @param {WordArray} The entropic value.
  # @param {Number} estimatedEntropy The estimated entropy of data, in bits
  # @param {String} source The source of the entropy, eg "mouse"
  #
  addEntropy: (data, estimatedEntropy, source = "user") ->
    t = Date.now()
    robin = @_robins[source]
    oldReady = @isReady()
    err = 0
      
    unless (id = @_collectorIds[source])?
      id = @_collectorIds[source] = @_collectorIdNext++
    robin = @_robins[source] = 0 unless robin?     
    @_robins[source] = ( @_robins[source] + 1 ) % @_pools.length

    tmp = (new WordArray [ id, @_eventId++, estimatedEntropy, t, data.length]).concat data
    @_pools[robin].update(new WordArray [ id, @_eventId++, estimatedEntropy, t, data.length]).update data
  
    # record the new strength
    @_poolEntropy[robin] += estimatedEntropy
    @_poolStrength += estimatedEntropy
  
    # fire off events
    if (oldReady === this._NOT_READY) {
      if (this.isReady() !== this._NOT_READY) {
        this._fireEvent("seeded", Math.max(this._strength, this._poolStrength));
      }
      this._fireEvent("progress", this.getProgress());
    }
  },
  
  /** Is the generator ready? */
  isReady: function (paranoia) {
    var entropyRequired = this._PARANOIA_LEVELS[ (paranoia !== undefined) ? paranoia : this._defaultParanoia ];
  
    if (this._strength && this._strength >= entropyRequired) {
      return (this._poolEntropy[0] > this._BITS_PER_RESEED && (new Date()).valueOf() > this._nextReseed) ?
        this._REQUIRES_RESEED | this._READY :
        this._READY;
    } else {
      return (this._poolStrength >= entropyRequired) ?
        this._REQUIRES_RESEED | this._NOT_READY :
        this._NOT_READY;
    }
  },
  
  /** Get the generator's progress toward readiness, as a fraction */
  getProgress: function (paranoia) {
    var entropyRequired = this._PARANOIA_LEVELS[ paranoia ? paranoia : this._defaultParanoia ];
  
    if (this._strength >= entropyRequired) {
      return 1.0;
    } else {
      return (this._poolStrength > entropyRequired) ?
        1.0 :
        this._poolStrength / entropyRequired;
    }
  },
  
  /** start the built-in entropy collectors */
  startCollectors: function () {
    if (this._collectorsStarted) { return; }
  
    if (window.addEventListener) {
      window.addEventListener("load", this._loadTimeCollector, false);
      window.addEventListener("mousemove", this._mouseCollector, false);
    } else if (document.attachEvent) {
      document.attachEvent("onload", this._loadTimeCollector);
      document.attachEvent("onmousemove", this._mouseCollector);
    }
    else {
      throw new sjcl.exception.bug("can't attach event");
    }
  
    this._collectorsStarted = true;
  },
  
  /** stop the built-in entropy collectors */
  stopCollectors: function () {
    if (!this._collectorsStarted) { return; }
  
    if (window.removeEventListener) {
      window.removeEventListener("load", this._loadTimeCollector, false);
      window.removeEventListener("mousemove", this._mouseCollector, false);
    } else if (window.detachEvent) {
      window.detachEvent("onload", this._loadTimeCollector);
      window.detachEvent("onmousemove", this._mouseCollector);
    }
    this._collectorsStarted = false;
  },
  
  /* use a cookie to store entropy.
  useCookie: function (all_cookies) {
      throw new sjcl.exception.bug("random: useCookie is unimplemented");
  },*/
  
  /** add an event listener for progress or seeded-ness. */
  addEventListener: function (name, callback) {
    this._callbacks[name][this._callbackI++] = callback;
  },
  
  /** remove an event listener for progress or seeded-ness */
  removeEventListener: function (name, cb) {
    var i, j, cbs=this._callbacks[name], jsTemp=[];
  
    /* I'm not sure if this is necessary; in C++, iterating over a
     * collection and modifying it at the same time is a no-no.
     */
  
    for (j in cbs) {
	if (cbs.hasOwnProperty(j) && cbs[j] === cb) {
        jsTemp.push(j);
      }
    }
  
    for (i=0; i<jsTemp.length; i++) {
      j = jsTemp[i];
      delete cbs[j];
    }
  },
  
  /** Generate 4 random words, no reseed, no gate.
   * @private
   */
  _gen4words: function () {
    for (var i=0; i<4; i++) {
      this._counter[i] = this._counter[i]+1 | 0;
      if (this._counter[i]) { break; }
    }
    return this._cipher.encrypt(this._counter);
  },
  
  /* Rekey the AES instance with itself after a request, or every _MAX_WORDS_PER_BURST words.
   * @private
   */
  _gate: function () {
    this._key = this._gen4words().concat(this._gen4words());
    this._cipher = new sjcl.cipher.aes(this._key);
  },
  
  /** Reseed the generator with the given words
   * @private
   */
  _reseed: function (seedWords) {
    this._key = sjcl.hash.sha256.hash(this._key.concat(seedWords));
    this._cipher = new sjcl.cipher.aes(this._key);
    for (var i=0; i<4; i++) {
      this._counter[i] = this._counter[i]+1 | 0;
      if (this._counter[i]) { break; }
    }
  },
  
  /** reseed the data from the entropy pools
   * @param full If set, use all the entropy pools in the reseed.
   */
  _reseedFromPools: function (full) {
    var reseedData = [], strength = 0, i;
  
    this._nextReseed = reseedData[0] =
      (new Date()).valueOf() + this._MILLISECONDS_PER_RESEED;
    
    for (i=0; i<16; i++) {
      /* On some browsers, this is cryptographically random.  So we might
       * as well toss it in the pot and stir...
       */
      reseedData.push(Math.random()*0x100000000|0);
    }
    
    for (i=0; i<this._pools.length; i++) {
     reseedData = reseedData.concat(this._pools[i].finalize());
     strength += this._poolEntropy[i];
     this._poolEntropy[i] = 0;
   
     if (!full && (this._reseedCount & (1<<i))) { break; }
    }
  
    /* if we used the last pool, push a new one onto the stack */
    if (this._reseedCount >= 1 << this._pools.length) {
     this._pools.push(new sjcl.hash.sha256());
     this._poolEntropy.push(0);
    }
  
    /* how strong was this reseed? */
    this._poolStrength -= strength;
    if (strength > this._strength) {
      this._strength = strength;
    }
  
    this._reseedCount ++;
    this._reseed(reseedData);
  },
  
  _mouseCollector: function (ev) {
    var x = ev.x || ev.clientX || ev.offsetX || 0, y = ev.y || ev.clientY || ev.offsetY || 0;
    sjcl.random.addEntropy([x,y], 2, "mouse");
  },
  
  _loadTimeCollector: function (ev) {
    sjcl.random.addEntropy((new Date()).valueOf(), 2, "loadtime");
  },
  
  _fireEvent: function (name, arg) {
    var j, cbs=sjcl.random._callbacks[name], cbsTemp=[];
    /* TODO: there is a race condition between removing collectors and firing them */ 

    /* I'm not sure if this is necessary; in C++, iterating over a
     * collection and modifying it at the same time is a no-no.
     */
  
    for (j in cbs) {
     if (cbs.hasOwnProperty(j)) {
        cbsTemp.push(cbs[j]);
     }
    }
  
    for (j=0; j<cbsTemp.length; j++) {
     cbsTemp[j](arg);
    }
  }
};

sjcl.random = new sjcl.prng(6);

(function(){
  try {
    // get cryptographically strong entropy in Webkit
    var ab = new Uint32Array(32);
    crypto.getRandomValues(ab);
    sjcl.random.addEntropy(ab, 1024, "crypto.getRandomValues");
  } catch (e) {
    // no getRandomValues :-(
  }
})();