package meatballcraft.e2e

import totoro.ocelot.brain.Ocelot
import totoro.ocelot.brain.entity.{CPU, Case, GraphicsCard, HDDManaged, InternetCard, Keyboard, LinkedCard, Memory, Screen, WirelessNetworkCard}
import totoro.ocelot.brain.event.{EventBus, MachineCrashEvent, TextBufferSetEvent}
import totoro.ocelot.brain.loot.Loot
import totoro.ocelot.brain.user.User
import totoro.ocelot.brain.util.{ExtendedTier, Tier}
import totoro.ocelot.brain.workspace.Workspace

import java.nio.charset.StandardCharsets
import java.nio.file.attribute.BasicFileAttributes
import java.nio.file.{FileVisitResult, Files, Path, Paths, SimpleFileVisitor}
import java.util.concurrent.atomic.{AtomicBoolean, AtomicReference}
import scala.jdk.CollectionConverters._

object Runner {
  private val ResultFile = ".e2e-result"
  private val TimeoutSeconds = 30
  private val ReactorNetworkProgram = "test/e2e/fixtures/reactor-network.lua"
  private val HeatNetworkProgram = "test/e2e/fixtures/heat-network.lua"

  def main(args: Array[String]): Unit = {
    val root = requiredEnvironmentPath("OC_E2E_ROOT")
    val requestedProgram = sys.env.getOrElse("OC_E2E_PROGRAM", "test/e2e/fixtures/smoke.lua")
    val program = root.resolve(requestedProgram).normalize()

    require(program.startsWith(root), s"program must be inside $root")
    require(Files.isRegularFile(program), s"program does not exist: $program")

    val temporaryRoot = Files.createTempDirectory("meatballcraft-ocelot-e2e-")
    val diskRoot = temporaryRoot.resolve("disk")
    val workspaceRoot = temporaryRoot.resolve("workspace")
    Files.createDirectories(diskRoot)
    Files.createDirectories(workspaceRoot)

    var initialized = false
    try {
      Ocelot.initialize()
      initialized = true
      if (requestedProgram == ReactorNetworkProgram) {
        runReactorNetwork(root, workspaceRoot, temporaryRoot)
      } else if (requestedProgram == HeatNetworkProgram) {
        runHeatNetwork(root, workspaceRoot, temporaryRoot)
      } else {
        if (requestedProgram == "test/e2e/fixtures/provision-drive.lua") {
          copyTree(
            root.resolve("test/ocelot-brain/src/main/resources/assets/opencomputers/loot/openos"),
            diskRoot
          )
          Files.deleteIfExists(diskRoot.resolve(".prop"))
          Files.writeString(
            diskRoot.resolve("etc/oppm.cfg"),
            "{path='/usr',repos={}}\n",
            StandardCharsets.UTF_8
          )
          Files.writeString(
            diskRoot.resolve("etc/opdata.svd"),
            "{_repos={['dyc3/meatballcraft-infra']={repo='dyc3/meatballcraft-infra'}}," +
              "oppm={['existing']='/usr/bin/oppm.lua'}}\n",
            StandardCharsets.UTF_8
          )
        }
        stageRepository(root, diskRoot)
        writeAutorun(diskRoot, root.relativize(program).toString.replace('\\', '/'))
        runComputer(root, workspaceRoot, diskRoot, requestedProgram)
      }
    } finally {
      if (initialized) Ocelot.shutdown()
      deleteTree(temporaryRoot)
    }
  }

  private case class TopologyComputer(computer: Case, screen: Screen, keyboard: Keyboard, diskRoot: Path)

  private def createTopologyComputer(
      root: Path,
      temporaryRoot: Path,
      workspace: Workspace,
      role: String,
      program: String,
      arguments: Seq[String],
      wireless: Boolean,
      linkedChannel: Option[String]
  ): TopologyComputer = {
    val roleRoot = temporaryRoot.resolve(s"$role-disk")
    Files.createDirectories(roleRoot)
    copyTree(root.resolve("test/ocelot-brain/src/main/resources/assets/opencomputers/loot/openos"), roleRoot)
    Files.deleteIfExists(roleRoot.resolve(".prop"))
    stageRepository(root, roleRoot)
    writeTopologyAutorun(roleRoot, program, arguments, role == "client" || role.endsWith("-client"))

    val computer = workspace.add(new Case(Tier.Creative))
    val screen = workspace.add(new Screen(Tier.Three))
    val keyboard = workspace.add(new Keyboard())
    computer.inventory(0) = new CPU(Tier.Three)
    computer.inventory(1) = new GraphicsCard(Tier.Three)
    computer.inventory(2) = new Memory(ExtendedTier.ThreeHalf)
    val eeprom = Loot.LuaBiosEEPROM.create()
    computer.inventory(3) = eeprom

    val disk = new HDDManaged(Tier.Three)
    disk.customRealPath = Some(roleRoot)
    disk.fileSystem.label.setLabel(s"e2e-$role")
    computer.inventory(4) = disk
    if (wireless) computer.inventory(5) = new WirelessNetworkCard.Tier2()
    linkedChannel.foreach { channel =>
      val card = new LinkedCard()
      card.tunnel = channel
      computer.inventory(6) = card
    }
    eeprom.volatileData = disk.node.address.getBytes(StandardCharsets.UTF_8)
    computer.connect(screen)
    screen.connect(keyboard)
    TopologyComputer(computer, screen, keyboard, roleRoot)
  }

  private def writeTopologyAutorun(
      diskRoot: Path,
      program: String,
      arguments: Seq[String],
      writesResult: Boolean
  ): Unit = {
    val escapedProgram = program.replace("\\", "\\\\").replace("\"", "\\\"")
    val luaArguments = arguments.map(value => "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\"")
      .mkString(", ")
    val resultBlock = if (writesResult) {
      s"""
         |local result, reason = io.open("/$ResultFile", "w")
         |assert(result, reason)
         |if ok then result:write("PASS\\n") else result:write("FAIL\\n", tostring(failure), "\\n") end
         |result:close()
         |computer.shutdown()
         |""".stripMargin
    } else {
      "if not ok then error(failure, 0) end\n"
    }

    val autorun =
      s"""local computer = require("computer")
         |package.path = "/lib/?.lua;/lib/?/init.lua;" .. package.path
         |local ok, failure = xpcall(function()
         |  local chunk, reason = loadfile("/repo/$escapedProgram")
         |  assert(chunk, reason)
         |  chunk($luaArguments)
         |end, debug.traceback)
         |$resultBlock
         |""".stripMargin
    Files.writeString(diskRoot.resolve("autorun.lua"), autorun, StandardCharsets.UTF_8)
  }

  private def pumpWorkspace(workspace: Workspace, milliseconds: Long): Unit = {
    val deadline = System.nanoTime() + milliseconds * 1000000L
    while (System.nanoTime() < deadline) {
      workspace.update()
      Thread.sleep(10)
    }
  }

  private def runReactorNetwork(root: Path, workspaceRoot: Path, temporaryRoot: Path): Unit = {
    val workspace = new Workspace(workspaceRoot)
    val channel = "meatballcraft-e2e-reactor"
    val server = createTopologyComputer(root, temporaryRoot, workspace, "server",
      "test/e2e/fixtures/reactor-network-server.lua", Seq.empty, wireless = false, Some(channel))
    val relay = createTopologyComputer(root, temporaryRoot, workspace, "relay",
      "nuclearcraft/reactor-relay.lua", Seq("--id=reactor-e2e", "--name=E2E Reactor"), wireless = true,
      Some(channel))
    val client = createTopologyComputer(root, temporaryRoot, workspace, "client", "nuclearcraft/reactor-client.lua",
      Seq("--reactor=reactor-e2e"), wireless = true, None)
    val computers = Seq(server, relay, client)

    val crash = new AtomicReference[String]()
    val connectedRendered = new AtomicBoolean(false)
    val onlineRendered = new AtomicBoolean(false)
    val completeRendered = new AtomicBoolean(false)
    val discoveringRendered = new AtomicBoolean(false)
    val discoveryCountRendered = new AtomicBoolean(false)
    val requestingRendered = new AtomicBoolean(false)
    val roles = computers.map(node => node.computer.node.address -> node).toMap
    EventBus.subscribe {
      case event: MachineCrashEvent if roles.contains(event.address) =>
        crash.compareAndSet(null, s"${roles(event.address).diskRoot.getFileName}: ${event.message}")
      case event: TextBufferSetEvent if event.address == client.screen.node.address =>
        if (event.value.contains("Discovering reactor relays")) discoveringRendered.set(true)
        if (event.value.contains("[1 discovered]")) discoveryCountRendered.set(true)
        if (event.value.contains("REQUESTING") || event.value.contains("Request sent")) requestingRendered.set(true)
        if (event.value.contains("CONNECTED")) connectedRendered.set(true)
        if (event.value.contains("ONLINE")) onlineRendered.set(true)
        if (event.value.contains("COMPLETE")) completeRendered.set(true)
    }

    server.computer.machine.start()
    pumpWorkspace(workspace, 2500)
    relay.computer.machine.start()
    pumpWorkspace(workspace, 2500)
    client.computer.machine.start()

    val menuDeadline = System.nanoTime() + 10L * 1000000000L
    while (!renderScreen(client.screen).contains("4. Live dashboard") && crash.get() == null &&
      System.nanoTime() < menuDeadline) {
      workspace.update()
      Thread.sleep(10)
    }
    if (!renderScreen(client.screen).contains("4. Live dashboard")) {
      throw new RuntimeException(s"Reactor client did not reach its real menu\n${renderScreen(client.screen)}")
    }

    val user = User("e2e")
    client.screen.keyDown('4', 5, user)
    client.screen.keyUp('4', 5, user)
    client.screen.keyDown('\r', 28, user)
    client.screen.keyUp('\r', 28, user)

    val resultPath = client.diskRoot.resolve(ResultFile)
    val deadline = System.nanoTime() + TimeoutSeconds * 1000000000L
    def clientConnected: Boolean = connectedRendered.get() && onlineRendered.get() && completeRendered.get()
    while (!clientConnected && !resultReady(resultPath) && crash.get() == null && System.nanoTime() < deadline) {
      workspace.update()
      Thread.sleep(10)
    }

    val screens = computers.zip(Seq("server", "relay", "client"))
      .map { case (node, role) => s"$role ${renderScreen(node.screen)}" }.mkString("\n")
    computers.foreach(_.computer.machine.stop())

    if (crash.get() != null) {
      throw new RuntimeException(s"OpenComputers topology crashed: ${crash.get()}\n$screens")
    } else if (resultReady(resultPath)) {
      val result = Files.readString(resultPath, StandardCharsets.UTF_8)
      throw new RuntimeException(s"Real reactor client exited:\n${result.stripPrefix("FAIL\n")}\n$screens")
    } else if (!clientConnected) {
      throw new RuntimeException(s"Real reactor client did not receive data after $TimeoutSeconds seconds\n$screens")
    } else if (!discoveringRendered.get() || !discoveryCountRendered.get() || !requestingRendered.get()) {
      throw new RuntimeException(
        s"Real reactor client did not render discovery/request diagnostics " +
          s"(discovering=${discoveringRendered.get()}, count=${discoveryCountRendered.get()}, " +
          s"requesting=${requestingRendered.get()})\n$screens"
      )
    }

    runEmptyReactorDiscovery(root, workspaceRoot.resolve("empty-discovery"), temporaryRoot)
    println(s"PASS: $ReactorNetworkProgram (real 3-computer topology plus real zero-provider discovery)")
  }

  private def runEmptyReactorDiscovery(root: Path, workspaceRoot: Path, temporaryRoot: Path): Unit = {
    Files.createDirectories(workspaceRoot)
    val workspace = new Workspace(workspaceRoot)
    val client = createTopologyComputer(root, temporaryRoot, workspace, "empty-client",
      "nuclearcraft/reactor-client.lua", Seq.empty, wireless = true, None)
    val crash = new AtomicReference[String]()
    val discoveringRendered = new AtomicBoolean(false)
    val zeroCountRendered = new AtomicBoolean(false)
    val troubleshootingRendered = new AtomicBoolean(false)

    EventBus.subscribe {
      case event: MachineCrashEvent if event.address == client.computer.node.address => crash.set(event.message)
      case event: TextBufferSetEvent if event.address == client.screen.node.address =>
        if (event.value.contains("Discovering reactor relays")) discoveringRendered.set(true)
        if (event.value.contains("0 valid reactor relays discovered")) zeroCountRendered.set(true)
        if (event.value.contains("no service responded") || event.value.contains("Check that the server is running")) {
          troubleshootingRendered.set(true)
        }
    }

    val resultPath = client.diskRoot.resolve(ResultFile)
    val deadline = System.nanoTime() + TimeoutSeconds * 1000000000L
    client.computer.machine.start()
    while (!resultReady(resultPath) && crash.get() == null && System.nanoTime() < deadline) {
      workspace.update()
      Thread.sleep(10)
    }

    val screen = renderScreen(client.screen)
    val result = if (Files.exists(resultPath)) Files.readString(resultPath, StandardCharsets.UTF_8) else ""
    client.computer.machine.stop()
    if (crash.get() != null) {
      throw new RuntimeException(s"Zero-provider reactor client crashed: ${crash.get()}\n$screen")
    } else if (!result.startsWith("PASS\n")) {
      throw new RuntimeException(s"Zero-provider reactor client did not exit cleanly: $result\n$screen")
    } else if (!discoveringRendered.get() || !zeroCountRendered.get() || !troubleshootingRendered.get()) {
      throw new RuntimeException(
        s"Zero-provider diagnostics were incomplete (discovering=${discoveringRendered.get()}, " +
          s"count=${zeroCountRendered.get()}, troubleshooting=${troubleshootingRendered.get()})\n$screen"
      )
    }
  }

  private def runHeatNetwork(root: Path, workspaceRoot: Path, temporaryRoot: Path): Unit = {
    val workspace = new Workspace(workspaceRoot)
    val server = createTopologyComputer(root, temporaryRoot, workspace, "heat-server",
      "test/e2e/fixtures/heat-network-server.lua", Seq.empty, wireless = true, None)
    val client = createTopologyComputer(root, temporaryRoot, workspace, "heat-client",
      "nuclearcraft/heat-client.lua", Seq("--exchanger=heat-e2e"), wireless = true, None)
    val computers = Seq(server, client)
    val crash = new AtomicReference[String]()
    val discovered = new AtomicBoolean(false)
    val requesting = new AtomicBoolean(false)
    val connected = new AtomicBoolean(false)
    val heatData = new AtomicBoolean(false)
    val roles = computers.map(node => node.computer.node.address -> node).toMap

    EventBus.subscribe {
      case event: MachineCrashEvent if roles.contains(event.address) =>
        crash.compareAndSet(null, s"${roles(event.address).diskRoot.getFileName}: ${event.message}")
      case event: TextBufferSetEvent if event.address == client.screen.node.address =>
        if (event.value.contains("[1 discovered]")) discovered.set(true)
        if (event.value.contains("REQUESTING") || event.value.contains("Request sent")) requesting.set(true)
        if (event.value.contains("CONNECTED")) connected.set(true)
        if (event.value.contains("Efficiency")) heatData.set(true)
    }

    server.computer.machine.start()
    pumpWorkspace(workspace, 2500)
    client.computer.machine.start()
    val menuDeadline = System.nanoTime() + 10L * 1000000000L
    while (!renderScreen(client.screen).contains("4. Live dashboard") && crash.get() == null &&
      System.nanoTime() < menuDeadline) {
      workspace.update()
      Thread.sleep(10)
    }
    if (!renderScreen(client.screen).contains("4. Live dashboard")) {
      throw new RuntimeException(s"Heat client did not reach its real menu\n${renderScreen(client.screen)}")
    }

    val user = User("e2e")
    client.screen.keyDown('4', 5, user)
    client.screen.keyUp('4', 5, user)
    client.screen.keyDown('\r', 28, user)
    client.screen.keyUp('\r', 28, user)

    val deadline = System.nanoTime() + TimeoutSeconds * 1000000000L
    while (!(discovered.get() && requesting.get() && connected.get() && heatData.get()) && crash.get() == null &&
      System.nanoTime() < deadline) {
      workspace.update()
      Thread.sleep(10)
    }
    val screens = computers.zip(Seq("server", "client"))
      .map { case (node, role) => s"$role ${renderScreen(node.screen)}" }.mkString("\n")
    computers.foreach(_.computer.machine.stop())

    if (crash.get() != null) {
      throw new RuntimeException(s"Heat topology crashed: ${crash.get()}\n$screens")
    } else if (!(discovered.get() && requesting.get() && connected.get() && heatData.get())) {
      throw new RuntimeException(
        s"Heat RPC diagnostics/data incomplete (discovered=${discovered.get()}, requesting=${requesting.get()}, " +
          s"connected=${connected.get()}, data=${heatData.get()})\n$screens"
      )
    }
    println(s"PASS: $HeatNetworkProgram (real 2-computer wireless discovery + heat RPC topology)")
  }

  private def runComputer(root: Path, workspaceRoot: Path, diskRoot: Path, program: String): Unit = {
    val workspace = new Workspace(workspaceRoot)
    val computer = workspace.add(new Case(Tier.Creative))
    val screen = workspace.add(new Screen(Tier.Three))
    val keyboard = workspace.add(new Keyboard())

    computer.inventory(0) = new CPU(Tier.Three)
    computer.inventory(1) = new GraphicsCard(Tier.Three)
    computer.inventory(2) = new Memory(ExtendedTier.ThreeHalf)
    val eeprom = Loot.LuaBiosEEPROM.create()
    computer.inventory(3) = eeprom
    computer.inventory(4) = Loot.OpenOsFloppy.create()

    val testDisk = new HDDManaged(Tier.Three)
    testDisk.customRealPath = Some(diskRoot)
    testDisk.fileSystem.label.setLabel("e2e")
    computer.inventory(5) = testDisk

    if (program == "test/e2e/fixtures/provision-drive.lua") {
      val oppmRoot = workspaceRoot.resolve("oppm-fixture")
      Files.createDirectories(oppmRoot.resolve("usr/bin"))
      Files.writeString(oppmRoot.resolve(".prop"), "{label='OPPM', reboot=false}\n", StandardCharsets.UTF_8)
      Files.writeString(
        oppmRoot.resolve(".install"),
        "local fs = require('filesystem')\n" +
          "local serialization = require('serialization')\n" +
          "local stateFile = assert(io.open('/etc/opdata.svd', 'r'))\n" +
          "local state = serialization.unserialize(stateFile:read('*a'))\n" +
          "stateFile:close()\n" +
          "if state.oppm then print('Package has already been installed') return false end\n" +
          "local to = install.to:gsub('//', '/')\n" +
          "if not fs.isDirectory(to .. 'usr/bin') then fs.makeDirectory(to .. 'usr/bin') end\n" +
          "local source = assert(io.open(install.from:gsub('//', '/') .. 'usr/bin/oppm.lua', 'r'))\n" +
          "local data = source:read('*a')\n" +
          "source:close()\n" +
          "data = data:gsub('if options%.iKnowWhatIAmDoing then', 'if true then', 1)\n" +
          "data = data:gsub('io%.stderr:write%(\"Please install oppm by running /bin/install%.lua\"%)', 'return')\n" +
          "local output, reason = io.open(to .. 'usr/bin/oppm.lua', 'w')\n" +
          "assert(output, reason)\n" +
          "output:write(data)\n" +
          "output:close()\n" +
          "state.oppm = {fixture = to .. 'usr/bin/oppm.lua'}\n" +
          "stateFile = assert(io.open('/etc/opdata.svd', 'w'))\n" +
          "stateFile:write(serialization.serialize(state))\n" +
          "stateFile:close()\n" +
          "return true\n",
        StandardCharsets.UTF_8
      )
      Files.copy(
        root.resolve("test/ocelot-brain/src/main/resources/assets/opencomputers/loot/oppm/usr/bin/oppm.lua"),
        oppmRoot.resolve("usr/bin/oppm.lua")
      )

      val oppmDisk = new HDDManaged(Tier.One)
      oppmDisk.customRealPath = Some(oppmRoot)
      oppmDisk.fileSystem.label.setLabel("oppm")
      computer.inventory(6) = oppmDisk

      val targetRoot = workspaceRoot.resolve("provision-target")
      Files.createDirectories(targetRoot.resolve("etc"))
      Files.writeString(targetRoot.resolve("stale-file"), "must be erased\n", StandardCharsets.UTF_8)
      Files.writeString(targetRoot.resolve("etc/opdata.svd"), "{oppm={stale='record'}}\n", StandardCharsets.UTF_8)
      val targetDisk = new HDDManaged(Tier.Three)
      targetDisk.customRealPath = Some(targetRoot)
      targetDisk.fileSystem.label.setLabel("provision-target")
      computer.inventory(7) = targetDisk
      computer.inventory(8) = new InternetCard()

      eeprom.volatileData = testDisk.node.address.getBytes(StandardCharsets.UTF_8)
    }

    computer.connect(screen)
    screen.connect(keyboard)

    val crash = new AtomicReference[String]()
    EventBus.subscribe {
      case event: MachineCrashEvent if event.address == computer.node.address => crash.set(event.message)
    }

    val resultPath = diskRoot.resolve(ResultFile)
    val deadline = System.nanoTime() + TimeoutSeconds * 1000000000L
    computer.machine.start()

    while (!resultReady(resultPath) && crash.get() == null && System.nanoTime() < deadline) {
      workspace.update()
      Thread.sleep(10)
    }

    val result = if (Files.exists(resultPath)) Files.readString(resultPath, StandardCharsets.UTF_8) else ""
    val screenText = renderScreen(screen)
    computer.machine.stop()

    if (crash.get() != null) {
      throw new RuntimeException(s"OpenComputers machine crashed: ${crash.get()}\n$screenText")
    } else if (!resultReady(resultPath)) {
      throw new RuntimeException(s"Timed out after $TimeoutSeconds seconds running $program\n$screenText")
    } else if (!result.startsWith("PASS\n")) {
      throw new RuntimeException(s"OpenComputers program failed:\n${result.stripPrefix("FAIL\n")}\n$screenText")
    }

    println(s"PASS: $program (Ocelot ${Ocelot.Version}, OpenOS 1.8.9)")
  }

  private def stageRepository(root: Path, diskRoot: Path): Unit = {
    val repositoryCopy = diskRoot.resolve("repo")
    Files.createDirectories(repositoryCopy)

    Files.walk(root).iterator().asScala
      .filter(Files.isRegularFile(_))
      .filter(path => path.getFileName.toString.endsWith(".lua") || path.getFileName.toString == "programs.cfg")
      .filterNot(_.startsWith(root.resolve("test/ocelot-brain")))
      .foreach { source =>
        val target = repositoryCopy.resolve(root.relativize(source).toString)
        Files.createDirectories(target.getParent)
        Files.copy(source, target)
      }

    val libraries = root.resolve("nuclearcraft/lib")
    if (Files.isDirectory(libraries)) copyTree(libraries, diskRoot.resolve("lib"))
    val discoveryLibraries = root.resolve("service-discovery/lib")
    if (Files.isDirectory(discoveryLibraries)) copyTree(discoveryLibraries, diskRoot.resolve("lib"))
  }

  private def writeAutorun(diskRoot: Path, program: String): Unit = {
    val escapedProgram = program.replace("\\", "\\\\").replace("\"", "\\\"")
    val autorun =
      s"""local computer = require("computer")
         |local filesystem = require("filesystem")
         |
         |local mount
         |for proxy, path in filesystem.mounts() do
         |  if proxy.getLabel() == "e2e" then
         |    mount = path
         |    break
         |  end
         |end
         |assert(mount, "e2e filesystem was not mounted")
         |
         |package.path = mount .. "/lib/?.lua;" .. mount .. "/lib/?/init.lua;" .. package.path
         |local target = mount .. "/repo/$escapedProgram"
         |local ok, failure = xpcall(function()
         |  local chunk, reason = loadfile(target)
         |  assert(chunk, reason)
         |  chunk()
         |end, debug.traceback)
         |
         |local result, reason = io.open(mount .. "/$ResultFile", "w")
         |assert(result, reason)
         |if ok then
         |  result:write("PASS\\n")
         |else
         |  result:write("FAIL\\n", tostring(failure), "\\n")
         |end
         |result:close()
         |computer.shutdown()
         |""".stripMargin

    Files.writeString(diskRoot.resolve("autorun.lua"), autorun, StandardCharsets.UTF_8)
  }

  private def renderScreen(screen: Screen): String = {
    val lines = screen.data.buffer.map(row => new String(row, 0, row.length).stripTrailing())
    val visible = lines.dropWhile(_.isBlank).reverse.dropWhile(_.isBlank).reverse
    if (visible.isEmpty) "" else visible.mkString("Emulated screen:\n", "\n", "")
  }

  private def resultReady(path: Path): Boolean = Files.exists(path) && Files.size(path) > 0

  private def copyTree(source: Path, target: Path): Unit = {
    Files.walk(source).iterator().asScala.foreach { path =>
      val destination = target.resolve(source.relativize(path).toString)
      if (Files.isDirectory(path)) Files.createDirectories(destination)
      else Files.copy(path, destination)
    }
  }

  private def deleteTree(root: Path): Unit = {
    if (Files.exists(root)) {
      Files.walkFileTree(root, new SimpleFileVisitor[Path] {
        override def visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult = {
          Files.deleteIfExists(file)
          FileVisitResult.CONTINUE
        }

        override def postVisitDirectory(dir: Path, error: java.io.IOException): FileVisitResult = {
          if (error != null) throw error
          Files.deleteIfExists(dir)
          FileVisitResult.CONTINUE
        }
      })
    }
  }

  private def requiredEnvironmentPath(name: String): Path = {
    Paths.get(sys.env.getOrElse(name, throw new IllegalArgumentException(s"missing environment variable: $name")))
      .toAbsolutePath.normalize()
  }
}
