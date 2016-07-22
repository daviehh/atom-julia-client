child_process = require 'child_process'
net =           require 'net'
path =          require 'path'
fs =            require 'fs'

{paths} = require '../misc'
messages = require './messages'
client = require './client'
tcp = require './tcp'

module.exports =

  activate: ->

    client.onConnected =>
      client.conn.proc?.removeListener? 'exit', @bootFailListener

    client.onDisconnected =>
      if @useWrapper and @proc
        @proc.kill()

  executable: ->
    if process.platform is 'win32' then 'julia.exe' else 'julia'

  packageDir: (s...) ->
    packageRoot = path.resolve __dirname, '..', '..'
    resourcePath = atom.config.resourcePath
    if path.extname(resourcePath) is '.asar' and packageRoot.indexOf(resourcePath) is 0
        packageRoot = path.join("#{resourcePath}.unpacked", 'node_modules', 'julia-client')
    path.join packageRoot, s...

  script: (s...) -> @packageDir 'script', s...

  monitorBoot: (proc) ->
    @bootFailListener ?= (code, signal) =>
      client.stderr "Julia has stopped"
      if not @useWrapper then client.stderr ": #{code}, #{signal}"
      client.cancelBoot()
    proc.on 'exit', @bootFailListener

  monitorStreams: (proc) ->
    proc.stdout.on 'data', (data) -> client.stdout data.toString()
    proc.stderr.on 'data', (data) -> client.stderr data.toString()

  init: (conn) ->
    conn.interrupt = => @interrupt conn.proc
    conn.kill = => @kill conn.proc
    conn.stdin = (data) -> conn.proc.stdin.write data
    client.connected conn

  start: (port) ->
    client.booting()
    paths.getVersion()
      .then =>
        @spawnJulia port, (proc) =>
          @monitorBoot proc
          @monitorStreams proc

          tcp.next().then (conn) =>
            conn.proc = proc
            @init conn
      .catch (err) =>
        messages.jlNotFound paths.jlpath(), err
        client.cancelBoot()

  spawnJulia: (port, fn) ->
    paths.workingDir().then (workingdir) =>
      if process.platform is 'win32' and atom.config.get("julia-client.enablePowershellWrapper")
        @useWrapper = parseInt(child_process.spawnSync("powershell",
                                                      ["-NoProfile", "$PSVersionTable.PSVersion.Major"])
                                            .output[1].toString()) > 2
        if @useWrapper
          @getFreePort =>
            # ordering of the last two arguments is important!
            jlargs = [client.clargs()..., "-i", '`"' + @script('boot.jl') + '`"', port]
            proc = child_process.spawn("powershell",
                                        ["-NoProfile", "-ExecutionPolicy", "bypass",
                                         "& \"#{@script "spawnInterruptible.ps1"}\"
                                         -cwd \"#{workingdir}\"
                                         -wrapPort #{@wrapPort}
                                         -jlpath \"#{paths.jlpath()}\"
                                         -jlargs #{jlargs}"])
            fn proc
          return
        else
          client.stderr "PowerShell version < 3 encountered. Running without wrapper (interrupts won't work)."
      proc = child_process.spawn paths.jlpath(),
        [client.clargs()..., "-i", @script("boot.jl"), port],
        cwd: workingdir
      fn proc

  getFreePort: (fn) ->
    server = net.createServer()
    server.listen 0, '127.0.0.1', =>
      @wrapPort = server.address().port
      server.close()
      fn()

  interrupt: (proc) ->
    if @useWrapper
      @sendSignalToWrapper('SIGINT')
    else
      proc.kill('SIGINT')

  kill: (proc) ->
    if @useWrapper
      @sendSignalToWrapper('KILL')
    else
      proc.kill()

  sendSignalToWrapper: (signal) ->
    wrapper = net.connect(port: @wrapPort)
    wrapper.setNoDelay()
    wrapper.write(signal)
    wrapper.end()
