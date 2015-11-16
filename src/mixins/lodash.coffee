_ = require 'lodash'

_.mixin
  mapPlucked: (obj, name) ->
    _.mapValues obj, _.partial _.pluck, _, name

  compactArray: (value) ->
    _.compact _.flatten [value]

  mapProperty: (value, prop) ->
    _.map value, _.property prop
