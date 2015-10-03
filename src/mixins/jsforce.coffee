Metadata = require 'jsforce/lib/api/metadata'

Metadata::cancelDeploy = (id, callback) ->
  @_invoke 'cancelDeploy', {id}, callback
