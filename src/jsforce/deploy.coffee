path = require 'path'
jsforce = require 'jsforce'
archiver = require 'archiver'
Promise = jsforce.Promise
gutil = require 'gulp-util'
_ = require 'lodash'

conn = deployLocator = null

connection = (_conn) ->
  if _conn? then conn = _conn else conn

deployFromZipStream = (zipStream, options) ->
  conn = connection()
  gutil.log 'Deploying to server...'
  conn.metadata.pollTimeout = options.pollTimeout or 60 * 1000
  conn.metadata.pollInterval = options.pollInterval or 5 * 1000
  conn.metadata.deploy zipStream, options

deployFromFileMapping = (mapping, options) ->
  archive = archiver 'zip'
  archive.bulk mapping
  archive.finalize()
  deployFromZipStream archive, options

deployFromDirectory = (packageDirectoryPath, options) ->
  deployFromFileMapping
    expand: true
    cwd: path.join packageDirectoryPath, '..'
    src: ["#{path.basename packageDirectoryPath}/**"]
  , options

reportDeployResult = (res) ->
  gutil.log do ->
    if res.success is 'SucceededPartial'
      'Deployment partially succeeded.'
    else if res.success
      'Deploy succeeded.'
    else if res.done
      'Deploy failed.'
    else
      'Deploy not completed yet.'

  if res.errorMessage
    gutil.log "#{res.errorStatusCode}: #{res.errorMessage}"

  gutil.log()
  gutil.log "Id: #{res.id}"
  gutil.log "Status: #{res.status}"
  gutil.log "Success: #{res.success}"
  gutil.log "Done: #{res.done}"
  gutil.log "Component Errors: #{res.numberComponentErrors}"
  gutil.log "Components Deployed: #{res.numberComponentsDeployed}"
  gutil.log "Components Total: #{res.numberComponentsTotal}"
  gutil.log "Test Errors: #{res.numberTestErrors}"
  gutil.log "Tests Completed: #{res.numberTestsCompleted}"
  gutil.log "Tests Total: #{res.numberTestsTotal}"
  reportDeployResultDetails()

reportDeployResultDetails = ->
  gutil.log ''

  if (failures = asArray details.componentFailures).length
    gutil.log 'Failures:'
    failures.forEach (f) ->
      gutil.log " - #{f.problemType} on #{f.fileName} : #{f.problem}"

  if (successes = asArray details.componentSuccesses).length
    gutil.log 'Successes:'
    successes.forEach (s) ->
      flag = switch 'true'
        when "#{s.changed}" then '(M)'
        when "#{s.created}" then '(A)'
        when "#{s.deleted}" then '(D)'
        else '(~)'
      gutil.log " - #{flag} #{s.fileName}#{if s.componentType then ' [' + s.componentType + ']' else ''}"

asArray = (arr) ->
  _.chain([arr]).flatten().compact()


class DeployResult

  constructor: (data={}) ->
    _.assign @, data
    @runTestResult = new RunTestResult @
    @componentResults = new ComponentResults @

  statusMessage: ->
    msg = ''
    state = @status ? @state
    if state?
      state = switch state
        when 'InProgress' then 'In Progress'
        else state
      msg += state + switch state
        when 'Canceled' then " by #{@canceledByName}"
        when 'Canceling' then ''
        else
          if @stateDetail? then " -- #{@stateDetail}" else ''
    msg

  getRecentFailures: (old) ->
    components: @componentResults.getRecentFailures old.componentResults
    tests: @runTestResult.getRecentFailures old.runTestResult

  reportFailures: (failures={}) ->
    console.log failures
    if failures.components?.length
      @componentResults.reportFailures failures.components
    if failures.tests?.length
      @runTestResult.reportFailures failures.tests

  report: -> reportDeployResult @

class RunTestResult

  constructor: (deployResult) ->
    _.assign @, deployResult.details?.runTestResult ? {}
    @failures = _.compact [@failures] unless _.isArray @failures

  getRecentFailures: (old) ->
    if old?.numFailures then @failures[old.numFailures..] else []

  reportFailures: (failures) ->
    return unless failures?.length
    sep = _.repeat '-', 80
    gutil.log sep
    gutil.log 'Test Failures:'
    failures.forEach (failure, i) ->
      indent = _.repeat ' ', (num = "#{i + 1}. ").length
      gutil.log "#{num}#{failure.name}.#{failure.methodName}"
      gutil.log indent + failure.message
      failure.stackTrace.split('\n').forEach (line) -> gutil.log indent + "#{line}"
    gutil.log sep


class ComponentResults
  constructor: (deployResult) ->
    @successes = deployResult.details?.componentSuccesses ? []

  getRecentFailures: (old) ->
    if old?.numFailures then @failures[old.numFailures..] else []

  reportFailures: (failures) ->
    return unless failures?.length
    sep = _.repeat '-', 80
    gutil.log sep
    gutil.log 'Component Failures:'
    failures.forEach (failure, i) ->
      indent = _.repeat ' ', (num = "#{i + 1}. ").length
      gutil.log "#{num}#{failure.name}.#{failure.methodName}"
      gutil.log indent + failure.message
      failure.stackTrace.split('\n').forEach (line) -> gutil.log indent + "#{line}"
    gutil.log sep


module.exports = {
  connection
  DeployResult
  deployFromZipStream
  deployFromFileMapping
  deployFromDirectory
  reportDeployResult
}
