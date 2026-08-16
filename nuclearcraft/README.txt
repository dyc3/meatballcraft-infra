NuclearCraft OpenComputers monitor scripts

Shared libraries
- nuclearcraft.ui contains the common client theme, metric formatting, scrolling views,
  dashboard refresh loop, drawing, and response handling.
- nuclearcraft.rpc provides linked-card and modem endpoints for serialized
  request/response traffic.
- nuclearcraft.service provides named-service selection from current discovery
  results. Clients prompt whenever multiple matching services are discovered.
- OPPM resolves the required libraries when installing each client or server package.
- OPPM installs shared modules through the nc-common and meatball-discovery
  dependency packages. Executable packages do not duplicate ownership of files
  under /lib.

Package ownership migration
- Packages installed before nc-common was introduced recorded shared /lib files
  as their own. OPPM cannot transfer that ownership during an update.
- Do not use oppm install -f: it leaves multiple packages claiming the same files.
- On an existing computer, note the installed nc-* packages with `oppm list -i`,
  uninstall all of those old nc-* packages, and also uninstall
  meatball-discovery if it is listed. Then install the packages you need again.
  Their nc-common and meatball-discovery dependencies will be installed once.
- Saved service configuration under /etc/nuclearcraft is not removed.

dashboard.lua
- Discovers every reactor relay, heat exchanger, turbine, and networked Geiger
  counter visible on the modem network; no per-service selection is required.
- Shows one live fleet view with connection state and headline metrics for every
  discovered instance. A failure from one server does not hide healthy servers.
- Each row uses granular colors for state, structure, labels, and metric values;
  a per-service spinner appears while its metrics request is in flight. Service
  names, state, structure, and type-specific metrics use aligned columns.
  Service names longer than the 32-character column are truncated with `~`.
- Radiation is red at 1 Rads/t and above, orange from 1 mRads/t, yellow from
  1 uRads/t, and white below 1 uRads/t (the nanorads range and smaller).
- Refreshes metrics every 2 seconds and repeats discovery every 30 seconds.
  Press r to refresh metrics, d to rediscover, or q to quit.

geiger-server.lua / geiger-client.lua
- Standalone Geiger counter monitor with no reactor dependency.
- Uses Linked Cards directly when they are present, without service discovery.
- Without a Linked Card, the server advertises over a Network Card and the
  client discovers named servers before using unicast RPC on port 48721.
- On first Network Card launch, the server asks for a stable ID and display
  name, then saves them in /etc/nuclearcraft/geiger-server.cfg.
- CLI values override and update the saved configuration, for example:
    geiger-server --id=geiger-north --name="North Geiger Counter"
- Pass --geiger=INSTANCE to the client for non-interactive selection.
- Opens directly into a live auto-refresh dashboard and displays chunk radiation
  in Rads/t with SI prefixes and the same severity colors as the fleet dashboard.

reactor-server.lua / reactor-relay.lua / reactor-client.lua
- Salt fission reactor + Geiger counter.
- The server checks reactor heat every second and deactivates the reactor when
  stored heat is rising above 50% capacity. Reactor responses retain the
  trigger heat and whether deactivation succeeded so clients can raise an alert.
- The server uses a Linked Card for the cross-dimensional link to the relay.
- The relay serves clients over normal Network Cards / component.modem.
- On first launch, the relay asks for a stable ID and display name, then saves
  them in /etc/nuclearcraft/reactor-relay.cfg.
- CLI values override and update the saved configuration, for example:
    reactor-relay --id=reactor-north --name="North Salt Reactor"
- The client uses a direct Linked Card immediately when present. Otherwise it
  discovers named relays over a Network Card, selects from the current results,
  and sends subsequent RPC requests directly to that relay's modem address.
- Pass --reactor=INSTANCE to the client to select a relay non-interactively.
- Port: 48723
- Reactor server, relay, and client use the same correlated nc-reactor-v1 RPC
  envelope. Update all three packages together and reboot their computers after
  updating so OpenOS reloads the shared RPC module.
- Reactor server normalizes NuclearCraft 2.19a getVesselStats() data.
- Client has compact scrollable views and a live auto-refresh dashboard.

heat-server.lua / heat-client.lua
- NuclearCraft heat exchanger.
- Summary dashboards use bounded aggregate responses. Detailed exchanger and
  condensation tube views are fetched in pages to stay within Network Card
  packet limits.
- Uses normal OpenComputers Network Cards / component.modem.
- On first launch, the server asks for a stable ID and display name, then saves
  them in /etc/nuclearcraft/heat-server.cfg.
- CLI values override and update the saved configuration, for example:
    heat-server --id=exchanger-north --name="North Heat Exchanger"
- Clients discover named servers and then use unicast RPC on port 48722.
- Pass --exchanger=INSTANCE to the client for non-interactive selection.
- Server interprets getExchangerTubeStats() and getCondensationTubeStats().
- Client has compact scrollable views and a live auto-refresh dashboard.
- Client/server check component.isAvailable("modem") before accessing component.modem.

turbine-server.lua / turbine-client.lua
- NuclearCraft turbine using normal OpenComputers Network Cards.
- On first launch, the server asks for a stable ID and display name, then saves
  them in /etc/nuclearcraft/turbine-server.cfg.
- CLI values override and update the saved configuration, for example:
    turbine-server --id=turbine-east --name="East Turbine"
- Clients discover named servers and then use unicast RPC on port 48724.
- Pass --turbine=INSTANCE to the client for non-interactive selection.
- Displays structure and processing state, power, stored energy, fluid input,
  flow, expansion, blade-stage efficiency, and dynamo-coil validity.
