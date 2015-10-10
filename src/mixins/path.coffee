path = require 'path'
_    = require 'lodash'

# extend path module with additional utility
_.extend path,
  # split into array of path segments
  split: (_path) -> _path.split path.sep

  # add to end of path and return the new path
  push: (_path, segments...) ->
    unless _.isString _path
      throw new TypeError "'_path' must be a string, not #{typeof _path}"
    segments.forEach (segment, i) ->
      unless _.isString segment
        throw new TypeError "Argument at index #{i} must be a string or undefined, not #{typeof segment}"
    arr = path.split _path
    arr.push.apply arr, segments
    path.join.apply path, arr

  # remove last path element, returning it and the new path
  pop: (_path) ->
    unless _.isString _path
      throw new TypeError "'_path' must be a string, not #{typeof _path}"
    [(arr = path.split _path).pop(), path.join.apply path, arr]

  # insert before first path element and return the new path
  unshift: (_path, segments...) ->
    unless _.isString _path
      throw new TypeError "'_path' must be a string, not #{typeof _path}"
    segments.forEach (segment, i) ->
      unless _.isString segment
        throw new TypeError "Argument at index #{i} must be a string or undefined, not #{typeof segment}"
    arr = path.split _path
    arr.unshift.apply arr, segments
    path.join.apply path, arr

  # remove first path element, returning it and the new path
  shift: (_path) ->
    unless _.isString _path
      throw new TypeError "'_path' must be a string, not #{typeof _path}"
    [(arr = path.split _path).shift(), path.join.apply path, arr]
