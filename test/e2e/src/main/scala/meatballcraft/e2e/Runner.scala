package meatballcraft.e2e

import totoro.ocelot.brain.Ocelot
import totoro.ocelot.brain.entity.{CPU, Case, GraphicsCard, HDDManaged, Keyboard, Memory, Screen}
import totoro.ocelot.brain.event.{EventBus, MachineCrashEvent}
import totoro.ocelot.brain.loot.Loot
import totoro.ocelot.brain.util.{ExtendedTier, Tier}
import totoro.ocelot.brain.workspace.Workspace

import java.nio.charset.StandardCharsets
import java.nio.file.attribute.BasicFileAttributes
import java.nio.file.{FileVisitResult, Files, Path, Paths, SimpleFileVisitor}
import java.util.concurrent.atomic.AtomicReference
import scala.jdk.CollectionConverters._

object Runner {
  private val ResultFile = ".e2e-result"
  private val TimeoutSeconds = 30

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
      stageRepository(root, diskRoot)
      writeAutorun(diskRoot, root.relativize(program).toString.replace('\\', '/'))

      Ocelot.initialize()
      initialized = true
      runComputer(workspaceRoot, diskRoot, requestedProgram)
    } finally {
      if (initialized) Ocelot.shutdown()
      deleteTree(temporaryRoot)
    }
  }

  private def runComputer(workspaceRoot: Path, diskRoot: Path, program: String): Unit = {
    val workspace = new Workspace(workspaceRoot)
    val computer = workspace.add(new Case(Tier.Creative))
    val screen = workspace.add(new Screen(Tier.Three))
    val keyboard = workspace.add(new Keyboard())

    computer.inventory(0) = new CPU(Tier.Three)
    computer.inventory(1) = new GraphicsCard(Tier.Three)
    computer.inventory(2) = new Memory(ExtendedTier.ThreeHalf)
    computer.inventory(3) = Loot.LuaBiosEEPROM.create()
    computer.inventory(4) = Loot.OpenOsFloppy.create()

    val testDisk = new HDDManaged(Tier.Three)
    testDisk.customRealPath = Some(diskRoot)
    testDisk.fileSystem.label.setLabel("e2e")
    computer.inventory(5) = testDisk

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
      .filter(_.getFileName.toString.endsWith(".lua"))
      .filterNot(_.startsWith(root.resolve("test/ocelot-brain")))
      .foreach { source =>
        val target = repositoryCopy.resolve(root.relativize(source).toString)
        Files.createDirectories(target.getParent)
        Files.copy(source, target)
      }

    val libraries = root.resolve("nuclearcraft/lib")
    if (Files.isDirectory(libraries)) copyTree(libraries, diskRoot.resolve("lib"))
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
