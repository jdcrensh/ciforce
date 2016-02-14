path = require 'path'
jsforce = require 'jsforce'
archiver = require 'archiver'
_ = require 'lodash'

conn = deployLocator = null

connection = (_conn) ->
  if _conn? then conn = _conn else conn

deployFromZipStream = (zipStream, options) ->
  conn = connection()
  console.log 'Deploying to server...'
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
  console.log do ->
    if res.success is 'SucceededPartial'
      'Deployment partially succeeded.'
    else if res.success
      'Deploy succeeded.'
    else if res.done
      'Deploy failed.'
    else
      'Deploy not completed yet.'

  if res.errorMessage
    console.log "#{res.errorStatusCode}: #{res.errorMessage}"

  console.log()
  console.log "Id: #{res.id}"
  console.log "Status: #{res.status}"
  console.log "Success: #{res.success}"
  console.log "Done: #{res.done}"
  console.log "Component Errors: #{res.numberComponentErrors}"
  console.log "Components Deployed: #{res.numberComponentsDeployed}"
  console.log "Components Total: #{res.numberComponentsTotal}"
  console.log "Test Errors: #{res.numberTestErrors}"
  console.log "Tests Completed: #{res.numberTestsCompleted}"
  console.log "Tests Total: #{res.numberTestsTotal}"
  reportDeployResultDetails()

reportDeployResultDetails = ->
  console.log ''

  if (failures = _.compactArray details?.componentFailures).length
    console.log 'Failures:'
    failures.forEach (f) ->
      console.log " - #{f.problemType} on #{f.fileName} : #{f.problem}"

  if (successes = _.compactArray details?.componentSuccesses).length
    console.log 'Successes:'
    successes.forEach (s) ->
      flag = switch 'true'
        when "#{s.changed}" then '(M)'
        when "#{s.created}" then '(A)'
        when "#{s.deleted}" then '(D)'
        else '(~)'
      console.log " - #{flag} #{s.fileName}#{if s.componentType then ' [' + s.componentType + ']' else ''}"


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
    console.log sep
    console.log 'Test Failures:'
    failures.forEach (failure, i) ->
      indent = _.repeat ' ', (num = "#{i + 1}. ").length
      console.log "#{num}#{failure.name}.#{failure.methodName}"
      console.log indent + failure.message
      failure.stackTrace.split('\n').forEach (line) -> console.log indent + "#{line}"
    console.log sep


class ComponentResults
  constructor: (deployResult) ->
    @successes = deployResult.details?.componentSuccesses ? []

  getRecentFailures: (old) ->
    if old?.numFailures then @failures[old.numFailures..] else []

  reportFailures: (failures) ->
    return unless failures?.length
    sep = _.repeat '-', 80
    console.log sep
    console.log 'Component Failures:'
    failures.forEach (failure, i) ->
      indent = _.repeat ' ', (num = "#{i + 1}. ").length
      console.log "#{num}#{failure.name}.#{failure.methodName}"
      console.log indent + failure.message
      failure.stackTrace.split('\n').forEach (line) -> console.log indent + "#{line}"
    console.log sep


module.exports = {
  connection
  DeployResult
  deployFromZipStream
  deployFromFileMapping
  deployFromDirectory
  reportDeployResult
}
