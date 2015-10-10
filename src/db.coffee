Loki = require 'lokijs'
loki = new Loki()

folderOverrides =
  EmailTemplate: 'Email'

###
# git file diffs
#
# Model:
#   path: String; eg. 'src/classes/Calculations.cls'
#   status: String; eg. 'M'
#   directory: String; eg. 'classes'
#   member: String; eg. 'Calculations'
###
diff = loki.addCollection 'diff'

###*
# global metadata describe
###
metadata = loki.addCollection 'metadataDescribe',
  indices: ['xmlName', 'xmlFolderName', 'directoryName']

metadata._onPreInsert = (obj) ->
  if obj.inFolder
    obj.xmlFolderName = (folderOverrides[obj.xmlName] ? obj.xmlName) + 'Folder'

metadata.on 'pre-insert', metadata._onPreInsert

###*
# org components describe
###
components = loki.addCollection 'componentDescribe',
  indices: ['fileName']

components._onPreUpsert = (obj) ->
  if obj.type is 'CustomObjectTranslation'
    obj.manageableState = if obj.fullName.match(/__.+__c/g)? then 'installed' else 'unmanaged'

  # set member type name used in package xml (i.e. *Folder types)
  describe = metadata.findObject xmlFolderName: obj.type
  obj.memberType = if describe? then describe.xmlName else obj.type

components._onUpsert = (obj) ->
  if obj.manageableState is 'installed'
    components.remove obj

components.on 'pre-insert', components._onPreUpsert
components.on 'insert', components._onUpsert
components.on 'update', components._onUpsert

###*
# org sobjects describe
###
global = loki.addCollection 'globalDescribe'

###*
# deploy results for components
###
componentResult = loki.addCollection 'componentResult'

###*
# deploy results for tests
###
runTestResult = loki.addCollection 'runTestResult'

# export
module.exports = {diff, metadata, components, global, componentResult, runTestResult}
