Loki = require 'lokijs'


class DbModule

  folderOverrides:
    EmailTemplate: 'Email'

  constructor: ->
    @loki = new Loki()

    ###
    # git file diffs
    #
    # Model:
    #   path: String; eg. 'src/classes/Calculations.cls'
    #   status: String; eg. 'M'
    #   directory: String; eg. 'classes'
    #   member: String; eg. 'Calculations'
    ###
    @diff = @loki.addCollection 'diff'

    # global metadata describe
    @metadata = @loki.addCollection 'metadataDescribe',
      indices: ['xmlName', 'directoryName']

    @metadata.on 'pre-insert', (obj) =>
      if obj.inFolder
        obj.xmlFolderName = (@folderOverrides[obj.xmlName] ? obj.xmlName) + 'Folder'

    # org components describe
    @components = @loki.addCollection 'componentDescribe', indices: ['fileName']

    @components.on 'pre-insert', (obj) ->
      if obj.type is 'CustomObjectTranslation'
        obj.managableState = if obj.fullName.match(/__.+__c/g)? then 'installed' else 'unmanaged'

    # org sobjects describe
    @global = @loki.addCollection 'globalDescribe'

    # deploy results for components
    @componentResult = @loki.addCollection 'componentResult'

    # deploy results for tests
    @runTestResult = @loki.addCollection 'runTestResult'

  insertComponent: (item) ->
    @components.insert item

  findChanges: ->
    @diff.find status: $in: 'ACMRT'.split ''

  findDeletes: ->
    @diff.find status: 'D'

  findDirectories: ->
    @metadata.find().map (obj) -> obj.directoryName

  findFolders: =>
    console.log 'finding folders...'
    @components.find type: $in: @metadata.find(inFolder: true).map (obj) -> obj.xmlName

  isManaged: (obj) ->
    obj.fullName?.match(/__[^_]+__c/g)?


module.exports = new DbModule()
