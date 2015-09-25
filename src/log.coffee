os       = require 'os'
{colors} = require 'gulp-util'


class LogModule
  noBreak: false

  timestamp: ->
    (d = new Date().toTimeString())[...d.indexOf ' ']

  syswrite: (msg='', ts=true) ->
    ts_str = if ts then "[#{colors.grey timestamp()}] " else ''
    process.stdout.write "#{ts_str}#{msg}", 'UTF-8'

  write: (msg='') ->
    @syswrite msg
    @noBreak = true

  writeln: (msg='') ->
    @syswrite msg + os.EOL
    @noBreak = false

  ok: (msg='') ->
    if msg
      @syswrite os.EOL, false if @noBreak
      @syswrite "#{colors.green '>> '}#{msg}#{os.EOL}"
      @noBreak = false
    else
      @syswrite "#{colors.green 'OK'}#{os.EOL}", !@noBreak
      @noBreak = true

  error: (msg) ->
    if msg
      @syswrite os.EOL, false if @noBreak
      @syswrite "#{colors.red '>> '}#{msg}#{os.EOL}"
      @noBreak = false
    else
      @syswrite "#{colors.green 'ERROR'}#{os.EOL}", !@noBreak
      @noBreak = true


module.exports = new LogModule()
