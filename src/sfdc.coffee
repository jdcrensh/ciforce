async        = require 'async'
gulp         = require 'gulp'
gutil        = require 'gulp-util'
del          = require 'del'
fs           = require 'fs-extra'
path         = require 'path'
zip          = require 'gulp-zip'
_            = require 'lodash'
console      = require 'better-console'
xpath        = require 'xpath'
xmlpoke        = require 'xmlpoke'
{DOMParser}  = require 'xmldom'

{config, db, events, jsforce} = require('require-dir') '.', recurse: true

conn = deployResult = lastDeployResult = canceled = null

SF_NAMESPACE = 'http://soap.sforce.com/2006/04/metadata'

SF_OPTS =
  username: if config.sfdc.sandbox
    "#{config.sfdc.username}.#{config.sfdc.sandbox}"
  else
    config.sfdc.username
  password: "#{config.sfdc.password}#{config.sfdc.securitytoken}"
  loginUrl: "https://#{['login', 'test'][~~!!config.sfdc.sandbox]}.salesforce.com"
  version: config.sfdc.version
  logger: gutil

excludes = {}

handleError = (err, done) ->
  gutil.log gutil.colors.red err
  done err, false

updateDeployResult = (res) ->
  [lastDeployResult, deployResult] = [deployResult, new jsforce.deploy.DeployResult res]
  deployResult

getDeployResult = ->
  deployResult ? {}

getCancelDeployResult = ->
  cancelDeployResult ? {}

getRunTestResult = ->
  deployResult?.runTestResult ? {}

getComponentResults = ->
  deployResult?.componentResults ? {}

typeQueries = ->
  db.metadata.find().map (obj) ->
    type: obj.xmlFolderName ? obj.xmlName

folderQueries = ->
  folderTypes = _.indexBy db.metadata.find(inFolder: true), 'xmlFolderName'
  db.components.find(type: $in: Object.keys folderTypes).map (obj) ->
    type: folderTypes[obj.type].xmlName
    folder: obj.fullName

listQuery = (query, next) ->
  conn.metadata.list query, (err, res) ->
    db.components.insert res if res?
    next err

# exitHandler = (options={}, err) -> ->
#   if not canceled and options.cancel and (res = getDeployResult())?.id
#     canceled = true
#     conn.metadata._invoke 'cancelDeploy', id: res.id
#   else if canceled
#     process.exit()
#
# process.on 'exit', exitHandler()
# process.on 'SIGINT', exitHandler cancel: true
# process.on 'uncaughtException', exitHandler()

deployComplete = (err, res, done) ->
  return handleError err, done if err
  res = getDeployResult()
  res.report()
  done res.success
  process.exit() if canceled

mapObjectComponentNames = (arr, filterFn) ->
  _.chain arr
    .compactArray()
    .mapProperty 'fullName'
    .compact()
    .filter filterFn
    .value()

module.exports =
  login: (done) ->
    jsforce.connect(SF_OPTS).then (_conn) ->
      jsforce.deploy.connection conn = _conn
    .catch done

  describeMetadata: (done) ->
    conn.metadata.describe().then (res) ->
      db.metadata.insert res.metadataObjects
    .catch done

  describeGlobal: (done) ->
    conn.describeGlobal().then (res) ->
      db.global.insert res.sobjects
    .catch done

  listMetadata: (done) ->
    # retrieve metadata listings in chunks, then folder contents
    async.eachSeries [typeQueries, folderQueries], (fn, next) ->
      async.each _.chunk(fn, 3), listQuery, next
    , done

  excludeManaged: (done) ->
    async.waterfall [
      (done) ->
        fs.readFile 'pkg/src/package.xml', 'utf-8', (err, xml) ->
          unless err
            doc = new DOMParser().parseFromString xml
            select = xpath.useNamespaces 'sf': SF_NAMESPACE
            nodes = select "//sf:name[text()='CustomObject']/../sf:members/text()", doc
            names = _.mapProperty nodes, 'nodeValue'
          done err, names

      (names, done) ->
        async.each _.chunk(names, 10), (names, done) ->
          conn.metadata.read('CustomObject', names).then (metadata) ->
            metadata = _.compactArray metadata
            async.each metadata, (meta, done) ->
              if meta.fullName
                excludes[meta.fullName] = {}
                mapping = excludes[meta.fullName]
                mapping.fields = mapObjectComponentNames meta.fields, (name) -> name.match /__.+__c$/g
                mapping.webLinks = mapObjectComponentNames meta.webLinks, (name) -> !!~name.indexOf '__'
                # mapping.listViewButtons = mapObjectComponentNames meta.searchLayouts
              async.setImmediate done
            , done
          .catch done
        , done
    ], (err) ->
      excludes.CustomObject = _.pick excludes.CustomObject, (types) -> _.some types, _.size
      done err

  removeExcludes: (done) ->
    async.forEachOf excludes.CustomObject, (types, name, done) ->
      xmlpoke "pkg/src/objects/#{name}.object", (xml) ->
        xml = xml.addNamespace 'sf', xml.SF_NAMESPACE
        ['fields', 'webLinks'].forEach (type) ->
          types[type].forEach (name) ->
            xml.remove "//sf:#{type}/sf:fullName[text()='#{name}']/.."
        done()
    , done

  validate: (done) ->
    # process.stdin.resume()

    async.during (done) ->
      res = getDeployResult()
      if res.id
        conn.metadata.checkDeployStatus(res.id, true).then (res) ->
          res = updateDeployResult res
          # res.reportFailures res.getRecentFailures lastDeployResult
          if lastDeployResult.lastModifiedDate isnt res.lastModifiedDate
            console.log res
          msg = res.statusMessage()
          if msg# and lastDeployResult.statusMessage() isnt msg
            if res.done
              gutil.log gutil.colors[if res.success then 'green' else 'red'] msg
            else
              gutil.log msg
          done null, not res.done
        .catch done
      else
        jsforce.deploy.deployFromDirectory path.join(config.git.dir, 'src'),
          checkOnly: true
          purgeOnDelete: true
          rollbackOnError: true
          runAllTests: false
          testLevel: 'RunLocalTests'
        .check (err, res) ->
          unless err
            gutil.log updateDeployResult(res).statusMessage()
          done err, true
    , (next) ->
      setTimeout next, 1000
    , (err) ->
      deployComplete err, done

  retrieve: (done) ->
    conn.metadata.retrieve(packageNames: 'unpackaged').then (res) ->
      gutil.log res
      res.pipe fs.createWriteStream 'pkg.zip'
      done()
    .catch (err) -> throw err

  project: (done) ->
    return done()
    del 'proj'
    mm = require 'mavensmate'
    client = mm.createClient
      name: 'mm-client'
      isNodeApp: true
      verbose: true
    client.executeCommand 'new-project',
      name: 'myproject'
      workspace: 'proj'
      username: config.sfdc.username
      password: config.sfdc.password + config.sfdc.securitytoken
      package: {}
