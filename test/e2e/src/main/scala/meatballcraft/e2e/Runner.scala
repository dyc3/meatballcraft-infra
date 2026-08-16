package meatballcraft.e2e

import totoro.ocelot.brain.Ocelot
import totoro.ocelot.brain.entity.{CPU, Case, GraphicsCard, HDDManaged, InternetCard, Keyboard, LinkedCard, Memory, NetworkCard, Screen, WirelessNetworkCard}
import totoro.ocelot.brain.event.{EventBus, MachineCrashEvent, TextBufferSetEvent}
import totoro.ocelot.brain.loot.Loot
import totoro.ocelot.brain.user.User
import totoro.ocelot.brain.util.{ExtendedTier, PackedColor, Tier}
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
  private val TurbineNetworkProgram = "test/e2e/fixtures/turbine-network.lua"
  private val GeigerNetworkProgram = "test/e2e/fixtures/geiger-network.lua"
  private val DashboardNetworkProgram = "test/e2e/fixtures/dashboard-network.lua"

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
      } else if (requestedProgram == TurbineNetworkProgram) {
        runTurbineNetwork(root, workspaceRoot, temporaryRoot)
      } else if (requestedProgram == GeigerNetworkProgram) {
        runGeigerNetwork(root, workspaceRoot, temporaryRoot)
      } else if (requestedProgram == DashboardNetworkProgram) {
        runDashboardNetwork(root, workspaceRoot, temporaryRoot)
      } else {
        if (requestedProgram == "test/e2e/fixtures/package-install.lua") {
          copyTree(
            root.resolve("test/ocelot-brain/src/main/resources/assets/opencomputers/loot/openos"),
            diskRoot
          )
          Files.deleteIfExists(diskRoot.resolve(".prop"))
        } else if (requestedProgram == "test/e2e/fixtures/provision-drive.lua") {
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
        if (requestedProgram == "test/e2e/fixtures/package-install.lua") {
          val stagedOppm = diskRoot.resolve("repo/test/e2e/fixtures/oppm-under-test.lua")
          Files.createDirectories(stagedOppm.getParent)
          Files.copy(
            root.resolve("test/ocelot-brain/src/main/resources/assets/opencomputers/loot/oppm/usr/bin/oppm.lua"),
            stagedOppm
          )
        }
        writeAutorun(diskRoot, root.relativize(program).toString.replace('\\', '/'))
        runComputer(root, workspaceRoot, diskRoot, requestedProgram)
      }
    } finally {
      if (initialized) Ocelot.shutdown()
      deleteTree(temporaryRoot)
    }
  }

  private case class TopologyComputer(
      computer: Case,
      screen: Screen,
      keyboard: Keyboard,
      diskRoot: Path,
      networkCard: Option[NetworkCard]
  )

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
    val networkCard = if (wireless) Some(new WirelessNetworkCard.Tier2()) else None
    networkCard.foreach(card => computer.inventory(5) = card)
    linkedChannel.foreach { channel =>
      val card = new LinkedCard()
      card.tunnel = channel
      computer.inventory(6) = card
    }
    eeprom.volatileData = disk.node.address.getBytes(StandardCharsets.UTF_8)
    computer.connect(screen)
    screen.connect(keyboard)
    TopologyComputer(computer, screen, keyboard, roleRoot, networkCard)
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
    val failsafeRendered = new AtomicBoolean(false)
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
        if (event.value.contains("FAILSAFE TRIGGERED") || event.value.contains("DEACTIVATION FAILED")) {
          failsafeRendered.set(true)
        }
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
    def clientConnected: Boolean = connectedRendered.get() && onlineRendered.get() && completeRendered.get() &&
      failsafeRendered.get()
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
    client.networkCard.foreach(_.openPorts.add(48722))
    val computers = Seq(server, client)
    val crash = new AtomicReference[String]()
    val discovered = new AtomicBoolean(false)
    val requesting = new AtomicBoolean(false)
    val connected = new AtomicBoolean(false)
    val heatData = new AtomicBoolean(false)
    val exchangerTubeData = new AtomicBoolean(false)
    val condensationTubeData = new AtomicBoolean(false)
    val roles = computers.map(node => node.computer.node.address -> node).toMap

    EventBus.subscribe {
      case event: MachineCrashEvent if roles.contains(event.address) =>
        crash.compareAndSet(null, s"${roles(event.address).diskRoot.getFileName}: ${event.message}")
      case event: TextBufferSetEvent if event.address == client.screen.node.address =>
        if (event.value.contains("[1 discovered]")) discovered.set(true)
        if (event.value.contains("REQUESTING") || event.value.contains("Request sent")) requesting.set(true)
        if (event.value.contains("CONNECTED")) connected.set(true)
        if (event.value.contains("Efficiency")) heatData.set(true)
        if (event.value.contains("300>315")) exchangerTubeData.set(true)
        if (event.value.contains("373 K")) condensationTubeData.set(true)
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
    while (!(discovered.get() && requesting.get() && connected.get() && heatData.get() && exchangerTubeData.get() &&
      condensationTubeData.get()) && crash.get() == null &&
      System.nanoTime() < deadline) {
      workspace.update()
      Thread.sleep(10)
    }
    val screens = computers.zip(Seq("server", "client"))
      .map { case (node, role) => s"$role ${renderScreen(node.screen)}" }.mkString("\n")
    computers.foreach(_.computer.machine.stop())

    if (crash.get() != null) {
      throw new RuntimeException(s"Heat topology crashed: ${crash.get()}\n$screens")
    } else if (!(discovered.get() && requesting.get() && connected.get() && heatData.get() &&
      exchangerTubeData.get() && condensationTubeData.get())) {
      throw new RuntimeException(
        s"Heat RPC diagnostics/data incomplete (discovered=${discovered.get()}, requesting=${requesting.get()}, " +
          s"connected=${connected.get()}, data=${heatData.get()}, exchangerTubes=${exchangerTubeData.get()}, " +
          s"condensationTubes=${condensationTubeData.get()})\n$screens"
      )
    }
    println(s"PASS: $HeatNetworkProgram (real 2-computer wireless discovery + heat RPC topology)")
  }

  private def runGeigerNetwork(root: Path, workspaceRoot: Path, temporaryRoot: Path): Unit = {
    val workspace = new Workspace(workspaceRoot)
    val server = createTopologyComputer(root, temporaryRoot, workspace, "geiger-server",
      "test/e2e/fixtures/geiger-network-server.lua", Seq.empty, wireless = true, None)
    val client = createTopologyComputer(root, temporaryRoot, workspace, "geiger-client",
      "nuclearcraft/geiger-client.lua", Seq("--geiger=geiger-e2e"), wireless = true, None)
    val computers = Seq(server, client)
    val crash = new AtomicReference[String]()
    val discovered = new AtomicBoolean(false)
    val requesting = new AtomicBoolean(false)
    val connected = new AtomicBoolean(false)
    val menuRendered = new AtomicBoolean(false)
    val roles = computers.map(node => node.computer.node.address -> node).toMap

    EventBus.subscribe {
      case event: MachineCrashEvent if roles.contains(event.address) =>
        crash.compareAndSet(null, s"${roles(event.address).diskRoot.getFileName}: ${event.message}")
      case event: TextBufferSetEvent if event.address == client.screen.node.address =>
        if (event.value.contains("[1 discovered]")) discovered.set(true)
        if (event.value.contains("REQUESTING") || event.value.contains("Request sent")) requesting.set(true)
        if (event.value.contains("CONNECTED")) connected.set(true)
        if (event.value.contains("Current radiation") || event.value.contains("Live dashboard")) menuRendered.set(true)
    }

    server.computer.machine.start()
    pumpWorkspace(workspace, 2500)
    client.computer.machine.start()

    val nano = new AtomicBoolean(false)
    val micro = new AtomicBoolean(false)
    val milli = new AtomicBoolean(false)
    val whole = new AtomicBoolean(false)
    val deadline = System.nanoTime() + TimeoutSeconds * 1000000000L
    def complete: Boolean = discovered.get() && requesting.get() && connected.get() && nano.get() && micro.get() &&
      milli.get() && whole.get()
    while (!complete && crash.get() == null && System.nanoTime() < deadline) {
      workspace.update()
      val rendered = renderScreen(client.screen)
      if (rendered.contains("42.0 nRads/t") &&
        textHasForeground(client.screen, "42.0 nRads/t", 0xFFFFFF)) nano.set(true)
      if (rendered.contains("420 uRads/t") &&
        textHasForeground(client.screen, "420 uRads/t", 0xFFFF55)) micro.set(true)
      if (rendered.contains("420 mRads/t") &&
        textHasForeground(client.screen, "420 mRads/t", 0xFFAA00)) milli.set(true)
      if (rendered.contains("1.20 Rads/t") &&
        textHasForeground(client.screen, "1.20 Rads/t", 0xFF5555)) whole.set(true)
      Thread.sleep(10)
    }

    val screens = computers.zip(Seq("server", "client"))
      .map { case (node, role) => s"$role ${renderScreen(node.screen)}" }.mkString("\n")
    computers.foreach(_.computer.machine.stop())

    if (crash.get() != null) {
      throw new RuntimeException(s"Geiger topology crashed: ${crash.get()}\n$screens")
    } else if (menuRendered.get()) {
      throw new RuntimeException(s"Geiger client rendered its removed request menu\n$screens")
    } else if (!complete) {
      throw new RuntimeException(
        s"Geiger diagnostics/colors incomplete (discovered=${discovered.get()}, requesting=${requesting.get()}, " +
          s"connected=${connected.get()}, nano=${nano.get()}, micro=${micro.get()}, milli=${milli.get()}, " +
          s"whole=${whole.get()})\n$screens"
      )
    }
    println(s"PASS: $GeigerNetworkProgram (direct live dashboard with radiation severity colors)")
  }

  private def runTurbineNetwork(root: Path, workspaceRoot: Path, temporaryRoot: Path): Unit = {
    val workspace = new Workspace(workspaceRoot)
    val server = createTopologyComputer(root, temporaryRoot, workspace, "turbine-server",
      "test/e2e/fixtures/turbine-network-server.lua", Seq.empty, wireless = true, None)
    val client = createTopologyComputer(root, temporaryRoot, workspace, "turbine-client",
      "nuclearcraft/turbine-client.lua", Seq("--turbine=turbine-e2e"), wireless = true, None)
    val computers = Seq(server, client)
    val crash = new AtomicReference[String]()
    val discovered = new AtomicBoolean(false)
    val requesting = new AtomicBoolean(false)
    val connected = new AtomicBoolean(false)
    val turbineData = new AtomicBoolean(false)
    val coilData = new AtomicBoolean(false)
    val energyData = new AtomicBoolean(false)
    val inputData = new AtomicBoolean(false)
    val flowData = new AtomicBoolean(false)
    val stageData = new AtomicBoolean(false)
    val roles = computers.map(node => node.computer.node.address -> node).toMap

    EventBus.subscribe {
      case event: MachineCrashEvent if roles.contains(event.address) =>
        crash.compareAndSet(null, s"${roles(event.address).diskRoot.getFileName}: ${event.message}")
      case event: TextBufferSetEvent if event.address == client.screen.node.address =>
        if (event.value.contains("[1 discovered]")) discovered.set(true)
        if (event.value.contains("REQUESTING") || event.value.contains("Request sent")) requesting.set(true)
        if (event.value.contains("CONNECTED")) connected.set(true)
        if (event.value.contains("Power: 12.3 kRF/t")) turbineData.set(true)
        if (event.value.contains("Coils: 2") && event.value.contains("Connectors: 1")) coilData.set(true)
        if (event.value.contains("Energy: 75.0%")) energyData.set(true)
        if (event.value.contains("Input: 400 mB/t")) inputData.set(true)
        if (event.value.contains("Flow: EAST")) flowData.set(true)
        if (event.value.contains("expansion 1.80/2.0") && event.value.contains("efficiency 80.0%")) stageData.set(true)
    }

    server.computer.machine.start()
    pumpWorkspace(workspace, 2500)
    client.computer.machine.start()
    val menuDeadline = System.nanoTime() + 10L * 1000000000L
    while (!renderScreen(client.screen).contains("2. Live dashboard") && crash.get() == null &&
      System.nanoTime() < menuDeadline) {
      workspace.update()
      Thread.sleep(10)
    }
    if (!renderScreen(client.screen).contains("2. Live dashboard")) {
      throw new RuntimeException(s"Turbine client did not reach its real menu\n${renderScreen(client.screen)}")
    }

    val user = User("e2e")
    client.screen.keyDown('2', 3, user)
    client.screen.keyUp('2', 3, user)
    client.screen.keyDown('\r', 28, user)
    client.screen.keyUp('\r', 28, user)

    val deadline = System.nanoTime() + TimeoutSeconds * 1000000000L
    def receivedTurbineData: Boolean = discovered.get() && requesting.get() && connected.get() &&
      turbineData.get() && coilData.get() && energyData.get() && inputData.get() && flowData.get() && stageData.get()
    while (!receivedTurbineData &&
      crash.get() == null && System.nanoTime() < deadline) {
      workspace.update()
      Thread.sleep(10)
    }
    val screens = computers.zip(Seq("server", "client"))
      .map { case (node, role) => s"$role ${renderScreen(node.screen)}" }.mkString("\n")
    computers.foreach(_.computer.machine.stop())

    if (crash.get() != null) {
      throw new RuntimeException(s"Turbine topology crashed: ${crash.get()}\n$screens")
    } else if (!receivedTurbineData) {
      throw new RuntimeException(
        s"Turbine RPC diagnostics/data incomplete (discovered=${discovered.get()}, requesting=${requesting.get()}, " +
          s"connected=${connected.get()}, power=${turbineData.get()}, coils=${coilData.get()}, " +
          s"energy=${energyData.get()}, input=${inputData.get()}, flow=${flowData.get()}, " +
          s"stages=${stageData.get()})\n$screens"
      )
    }
    println(s"PASS: $TurbineNetworkProgram (real client/server entry points over 2-computer wireless topology)")
  }

  private def runDashboardNetwork(root: Path, workspaceRoot: Path, temporaryRoot: Path): Unit = {
    val workspace = new Workspace(workspaceRoot)
    val channel = "meatballcraft-e2e-dashboard-reactor"
    val reactorServer = createTopologyComputer(root, temporaryRoot, workspace, "dashboard-reactor-server",
      "test/e2e/fixtures/reactor-network-server.lua", Seq.empty, wireless = false, Some(channel))
    val reactorRelay = createTopologyComputer(root, temporaryRoot, workspace, "dashboard-reactor-relay",
      "nuclearcraft/reactor-relay.lua", Seq("--id=reactor-e2e", "--name=E2E Reactor"), wireless = true,
      Some(channel))
    val heatServer = createTopologyComputer(root, temporaryRoot, workspace, "dashboard-heat-server",
      "test/e2e/fixtures/dashboard-heat-server.lua", Seq.empty, wireless = true, None)
    val turbineServer = createTopologyComputer(root, temporaryRoot, workspace, "dashboard-turbine-server",
      "test/e2e/fixtures/turbine-network-server.lua", Seq.empty, wireless = true, None)
    val nanoGeiger = createTopologyComputer(root, temporaryRoot, workspace, "dashboard-geiger-nano",
      "test/e2e/fixtures/dashboard-geiger-server.lua",
      Seq("geiger-nano", "Nano Radiation Monitor With Long Name", "0.000000042"),
      wireless = true, None)
    val microGeiger = createTopologyComputer(root, temporaryRoot, workspace, "dashboard-geiger-micro",
      "test/e2e/fixtures/dashboard-geiger-server.lua", Seq("geiger-micro", "Micro Radiation", "0.00042"),
      wireless = true, None)
    val milliGeiger = createTopologyComputer(root, temporaryRoot, workspace, "dashboard-geiger-milli",
      "test/e2e/fixtures/dashboard-geiger-server.lua", Seq("geiger-milli", "Milli Radiation", "0.42"),
      wireless = true, None)
    val highGeiger = createTopologyComputer(root, temporaryRoot, workspace, "dashboard-geiger-high",
      "test/e2e/fixtures/dashboard-geiger-server.lua", Seq("geiger-high", "High Radiation", "1.2"),
      wireless = true, None)
    val dashboard = createTopologyComputer(root, temporaryRoot, workspace, "dashboard-client",
      "nuclearcraft/dashboard.lua", Seq.empty, wireless = true, None)
    val providers = Seq(reactorRelay, heatServer, turbineServer, nanoGeiger, microGeiger, milliGeiger, highGeiger)
    val computers = Seq(reactorServer) ++ providers ++ Seq(dashboard)
    val roles = computers.map(node => node.computer.node.address -> node).toMap
    val crash = new AtomicReference[String]()
    val discovering = new AtomicBoolean(false)
    val discoveryCounts = new AtomicBoolean(false)
    val reactor = new AtomicBoolean(false)
    val reactorFailsafe = new AtomicBoolean(false)
    val heat = new AtomicBoolean(false)
    val turbine = new AtomicBoolean(false)
    val geiger = new AtomicBoolean(false)
    val spinner = new AtomicBoolean(false)
    val granularStateColors = new AtomicBoolean(false)
    val radiationColors = new AtomicBoolean(false)
    val alignedColumns = new AtomicBoolean(false)

    EventBus.subscribe {
      case event: MachineCrashEvent if roles.contains(event.address) =>
        crash.compareAndSet(null, s"${roles(event.address).diskRoot.getFileName}: ${event.message}")
      case event: TextBufferSetEvent if event.address == dashboard.screen.node.address =>
        if (event.value.contains("Discovering NuclearCraft services")) discovering.set(true)
        if (event.value == "[|]" || event.value == "[/]" || event.value == "[-]" || event.value == "[\\]") {
          spinner.set(true)
        }
    }

    reactorServer.computer.machine.start()
    pumpWorkspace(workspace, 1500)
    providers.foreach { node =>
      node.computer.machine.start()
      pumpWorkspace(workspace, 750)
    }
    dashboard.computer.machine.start()

    val deadline = System.nanoTime() + TimeoutSeconds * 1000000000L
    def complete: Boolean = discovering.get() && discoveryCounts.get() && reactor.get() && reactorFailsafe.get() &&
      heat.get() && turbine.get() && geiger.get() && spinner.get() && granularStateColors.get() &&
      radiationColors.get() && alignedColumns.get()
    while (!complete && crash.get() == null && System.nanoTime() < deadline) {
      workspace.update()
      val rendered = renderScreen(dashboard.screen)
      if (rendered.contains("7 services discovered")) discoveryCounts.set(true)
      if (rendered.contains("E2E Reactor") && rendered.contains("ONLINE") && rendered.contains("COMPLETE")) reactor.set(true)
      if (rendered.contains("E2E Reactor") && rendered.contains("FAILSAFE FAILED") &&
        textHasForeground(dashboard.screen, "FAILSAFE FAILED", 0xFF5555)) reactorFailsafe.set(true)
      if (rendered.contains("E2E Heat Exchanger") && rendered.contains("80.0%") &&
        rendered.contains("OFFLINE") && rendered.contains("INCOMPLETE")) heat.set(true)
      if (rendered.contains("E2E Turbine") && rendered.contains("12.3 kRF/t")) turbine.set(true)
      if (rendered.contains("42.0 nRads/t") && rendered.contains("420 uRads/t") &&
        rendered.contains("420 mRads/t") && rendered.contains("1.20 Rads/t")) geiger.set(true)
      if (textHasForeground(dashboard.screen, "ONLINE", 0x55FF55) &&
          textHasForeground(dashboard.screen, "COMPLETE", 0x55FF55) &&
          textHasForeground(dashboard.screen, "OFFLINE", 0xFFFF55) &&
          textHasForeground(dashboard.screen, "INCOMPLETE", 0xFFFF55) &&
          textHasForeground(dashboard.screen, "E2E Reactor", 0xFFFFFF)) granularStateColors.set(true)
      if (textHasForeground(dashboard.screen, "1.20 Rads/t", 0xFF5555) &&
          textHasForeground(dashboard.screen, "420 mRads/t", 0xFFAA00) &&
          textHasForeground(dashboard.screen, "420 uRads/t", 0xFFFF55) &&
          textHasForeground(dashboard.screen, "42.0 nRads/t", 0xFFFFFF)) radiationColors.set(true)
      val onlineColumn = textColumn(dashboard.screen, "E2E Reactor", "ONLINE")
      val offlineColumn = textColumn(dashboard.screen, "E2E Heat Exchanger", "OFFLINE")
      val completeColumn = textColumn(dashboard.screen, "E2E Reactor", "COMPLETE")
      val incompleteColumn = textColumn(dashboard.screen, "E2E Heat Exchanger", "INCOMPLETE")
      val radiationColumns = Seq("Nano Radiation Monitor With Lon~", "Micro Radiation", "Milli Radiation", "High Radiation")
        .map(name => textColumn(dashboard.screen, name, "| Radiation"))
      if (
        onlineColumn >= 0 && onlineColumn == offlineColumn &&
          completeColumn >= 0 && completeColumn == incompleteColumn &&
          radiationColumns.forall(_ >= 0) && radiationColumns.distinct.size == 1 &&
          rendered.contains("Nano Radiation Monitor With Lon~") &&
          !rendered.contains("Nano Radiation Monitor With Long Name")
      ) alignedColumns.set(true)
      Thread.sleep(10)
    }

    val rolesInOrder = Seq("reactor-server", "reactor-relay", "heat-server", "turbine-server", "nano-geiger",
      "micro-geiger", "milli-geiger", "high-geiger", "dashboard")
    val screens = computers.zip(rolesInOrder).map { case (node, role) => s"$role ${renderScreen(node.screen)}" }.mkString("\n")
    computers.foreach(_.computer.machine.stop())

    if (crash.get() != null) {
      throw new RuntimeException(s"Dashboard topology crashed: ${crash.get()}\n$screens")
    } else if (!complete) {
      throw new RuntimeException(
        s"Dashboard did not render the complete fleet (discovering=${discovering.get()}, " +
          s"counts=${discoveryCounts.get()}, reactor=${reactor.get()}, reactorFailsafe=${reactorFailsafe.get()}, " +
          s"heat=${heat.get()}, " +
          s"turbine=${turbine.get()}, geiger=${geiger.get()}, spinner=${spinner.get()}, " +
          s"stateColors=${granularStateColors.get()}, radiationColors=${radiationColors.get()}, " +
          s"aligned=${alignedColumns.get()})\n$screens"
      )
    }
    runEmptyDashboard(root, workspaceRoot.resolve("dashboard-empty"), temporaryRoot)
    runFailingDashboard(root, workspaceRoot.resolve("dashboard-failures"), temporaryRoot)
    println(s"PASS: $DashboardNetworkProgram (healthy fleet, zero-provider, and isolated RPC failures)")
  }

  private def runEmptyDashboard(root: Path, workspaceRoot: Path, temporaryRoot: Path): Unit = {
    Files.createDirectories(workspaceRoot)
    val workspace = new Workspace(workspaceRoot)
    val dashboard = createTopologyComputer(root, temporaryRoot, workspace, "dashboard-empty-client",
      "nuclearcraft/dashboard.lua", Seq.empty, wireless = true, None)
    val crash = new AtomicReference[String]()
    val zeroCount = new AtomicBoolean(false)
    val troubleshooting = new AtomicBoolean(false)
    EventBus.subscribe {
      case event: MachineCrashEvent if event.address == dashboard.computer.node.address => crash.set(event.message)
      case event: TextBufferSetEvent if event.address == dashboard.screen.node.address =>
        if (event.value.contains("0 services discovered")) zeroCount.set(true)
        if (event.value.contains("Check servers, wireless range, and discovery port 48700")) troubleshooting.set(true)
    }

    dashboard.computer.machine.start()
    val deadline = System.nanoTime() + 15L * 1000000000L
    while (!(zeroCount.get() && troubleshooting.get()) && crash.get() == null && System.nanoTime() < deadline) {
      workspace.update()
      Thread.sleep(10)
    }
    val screen = renderScreen(dashboard.screen)
    dashboard.computer.machine.stop()
    if (crash.get() != null) {
      throw new RuntimeException(s"Zero-provider dashboard crashed: ${crash.get()}\n$screen")
    } else if (!(zeroCount.get() && troubleshooting.get())) {
      throw new RuntimeException(
        s"Zero-provider dashboard diagnostics incomplete (count=${zeroCount.get()}, " +
          s"troubleshooting=${troubleshooting.get()})\n$screen"
      )
    }
  }

  private def runFailingDashboard(root: Path, workspaceRoot: Path, temporaryRoot: Path): Unit = {
    Files.createDirectories(workspaceRoot)
    val workspace = new Workspace(workspaceRoot)
    val provider = createTopologyComputer(root, temporaryRoot, workspace, "dashboard-failure-server",
      "test/e2e/fixtures/dashboard-failure-server.lua", Seq.empty, wireless = true, None)
    val dashboard = createTopologyComputer(root, temporaryRoot, workspace, "dashboard-failure-client",
      "nuclearcraft/dashboard.lua", Seq.empty, wireless = true, None)
    val computers = Seq(provider, dashboard)
    val roles = computers.map(node => node.computer.node.address -> node).toMap
    val crash = new AtomicReference[String]()
    val timeout = new AtomicBoolean(false)
    val handlerFailure = new AtomicBoolean(false)
    val malformed = new AtomicBoolean(false)
    EventBus.subscribe {
      case event: MachineCrashEvent if roles.contains(event.address) =>
        crash.compareAndSet(null, s"${roles(event.address).diskRoot.getFileName}: ${event.message}")
      case event: TextBufferSetEvent if event.address == dashboard.screen.node.address =>
        if (event.value.contains("Request sent; no response received")) timeout.set(true)
        if (event.value.contains("Server error: fixture handler failure")) handlerFailure.set(true)
        if (event.value.contains("'radiation' data is missing or invalid")) malformed.set(true)
    }

    provider.computer.machine.start()
    pumpWorkspace(workspace, 1000)
    dashboard.computer.machine.start()
    val deadline = System.nanoTime() + TimeoutSeconds * 1000000000L
    def complete: Boolean = timeout.get() && handlerFailure.get() && malformed.get()
    while (!complete && crash.get() == null && System.nanoTime() < deadline) {
      workspace.update()
      Thread.sleep(10)
    }
    val screens = computers.zip(Seq("failure-provider", "dashboard"))
      .map { case (node, role) => s"$role ${renderScreen(node.screen)}" }.mkString("\n")
    computers.foreach(_.computer.machine.stop())
    if (crash.get() != null) {
      throw new RuntimeException(s"Failure dashboard topology crashed: ${crash.get()}\n$screens")
    } else if (!complete) {
      throw new RuntimeException(
        s"Dashboard failure diagnostics incomplete (timeout=${timeout.get()}, " +
          s"handler=${handlerFailure.get()}, malformed=${malformed.get()})\n$screens"
      )
    }
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
    } else if (program == "test/e2e/fixtures/package-install.lua") {
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

  private def textHasForeground(screen: Screen, text: String, expected: Int): Boolean = {
    val format = screen.data.format
    val normalizedExpected = format.inflate(format.deflate(PackedColor.Color(expected)) & 0xFF)
    screen.data.buffer.indices.exists { row =>
      val rendered = new String(screen.data.buffer(row), 0, screen.data.buffer(row).length)
      var index = rendered.indexOf(text)
      var matched = false
      while (index >= 0 && !matched) {
        val actual = PackedColor.unpackForeground(screen.data.color(row)(index), format)
        matched = actual == normalizedExpected
        index = rendered.indexOf(text, index + 1)
      }
      matched
    }
  }

  private def textColumn(screen: Screen, lineMarker: String, text: String): Int = {
    screen.data.buffer.iterator.map(row => new String(row, 0, row.length))
      .find(_.contains(lineMarker)).map(_.indexOf(text)).getOrElse(-1)
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
