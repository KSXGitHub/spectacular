
spectacular.helper 'createEnv', (block, context, options) ->
  env = spectacular.env.clone()
  env.options.colors = false
  env.options.format = 'documentation'
  env.options.valueOutput = (str) -> str
  env.options[k] = v for k,v of options
  context.results = ''

  spyOn(env, 'globalize').andCallThrough ->
    promise = spectacular.Promise.unit()
    promise.then -> do block

  env

spectacular.helper 'createReporter', (env, context, async) ->
  reporter = spectacular.ConsoleReporter.getDefault env.options
  context.results = ''
  reporter.on 'message', (e) -> context.results += e.target
  reporter.on 'report', (e) ->
    context.results += e.target
    if context.ended
      if context.rejected?
        async.reject context.rejected
      else
        async.resolve()

    context.ended = true

  env.runner.on 'message', reporter.onMessage
  env.runner.on 'result', reporter.onResult
  env.runner.on 'end', reporter.onEnd
  reporter

spectacular.helper 'runEnvExpectingNormalTermination', (env, context, async) ->
  oldEnv = spectacular.env
  oldEnv.unglobalize()
  spectacular.env = env
  env.globalize()
  .then ->
    env.run()
  .then (status) ->
    context.status = status
    spectacular.env.unglobalize()
    spectacular.env = oldEnv
    oldEnv.globalize()
    async.resolve() if context.ended
    context.ended = true
  .fail (reason) ->
    context.reason = context.rejected = reason
    spectacular.env.unglobalize()
    spectacular.env = oldEnv
    oldEnv.globalize()
    async.reject reason

spectacular.helper 'runEnvExpectingInterruption', (env, context, async) ->
  oldEnv = spectacular.env
  oldEnv.unglobalize()
  spectacular.env = env
  env.globalize()
  .then ->
    env.run()
  .then (status) =>
    spectacular.env = oldEnv
    spectacular.env.unglobalize()
    oldEnv.globalize()
    context.rejected = new Error "run didn't failed"
    async.reject context.rejected if context.ended
    context.ended = true
  .fail (reason) =>
    spectacular.env = oldEnv
    spectacular.env.unglobalize()
    context.reason = reason
    oldEnv.globalize()
    async.resolve()

spectacular.helper 'runningSpecs', (desc) ->
  options = {}

  withOption: (option, value) ->
    options[option] = value
    this

  shouldFailWith: (re, block) ->
    describe "running specs with #{desc}", ->
      before (async) ->
        @env = createEnv block, this, options
        @reporter = createReporter @env, this, async
        runEnvExpectingNormalTermination @env, this, async

      specify 'the status', -> @status.should be 1
      specify 'the results', -> @results.should match re

    this

  shouldSucceedWith: (re, block) ->
    describe "running specs with #{desc}", ->
      before (async) ->
        @env = createEnv block, this, options
        @reporter = createReporter @env, this, async
        runEnvExpectingNormalTermination @env, this, async

      specify 'the status', -> @status.should be 0
      specify 'the results', -> @results.should match re

    this

  shouldStopWith: (re, block) ->
    describe "running specs with #{desc}", ->
      before (async) ->
        @env = createEnv block, this, options
        @reporter = createReporter @env, this, async
        runEnvExpectingInterruption @env, this, async

      specify 'the error message', ->
        @reason.message.should match re

    this

spectacular.helper 'environmentMethod', (method) ->
  cannotBeCalledInsideIt: ->
    runningSpecs('call inside it')
    .shouldFailWith /called inside a it block/, ->
      describe 'foo', ->
        it -> spectacular.global[method]()

  cannotBeCalledOutsideIt: ->
    runningSpecs('call outside it')
    .shouldStopWith /called outside a it block/, ->
      describe 'foo', -> spectacular.global[method]()

  cannotBeCalledWithoutPreviousSubject: ->
    runningSpecs('call in context without previous subject')
    .shouldStopWith /called in context without a previous subject/, ->
      describe 'foo', -> spectacular.global[method]()

  cannotBeCalledWithoutMatcher: ->
    runningSpecs('call without matcher')
    .shouldFailWith /called without a matcher/, ->
      specify -> spectacular.global[method]()
