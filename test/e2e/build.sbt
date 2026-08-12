ThisBuild / scalaVersion := "2.13.10"

lazy val ocelotBrain = RootProject(file("../ocelot-brain"))

lazy val e2e = project
  .in(file("."))
  .dependsOn(ocelotBrain)
  .settings(
    name := "meatballcraft-e2e",
    Compile / run / fork := true,
    Compile / run / connectInput := false,
    Compile / run / outputStrategy := Some(StdoutOutput)
  )
