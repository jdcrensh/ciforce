_ = require 'lodash'

_.mixin
  mapPlucked: (obj, name) ->
    _.mapValues obj, _.partial _.pluck, _, name
