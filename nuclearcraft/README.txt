NuclearCraft OpenComputers monitor scripts

Shared libraries
- nuclearcraft.ui contains the common client theme, metric formatting, scrolling views,
  dashboard refresh loop, drawing, and response handling.
- nuclearcraft.rpc provides linked-card and modem endpoints for serialized
  request/response traffic.
- nuclearcraft.service provides named-service selection and remembers the
  selected instance ID while rediscovering its current modem address each run.
- OPPM installs the required libraries with each client or server package.

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
- Displays chunk radiation in Rads/t with SI prefixes.
- Client has a compact reading view and a live auto-refresh dashboard.

reactor-server.lua / reactor-relay.lua / reactor-client.lua
- Salt fission reactor + Geiger counter.
- The server uses a Linked Card for the cross-dimensional link to the relay.
- The relay serves clients over normal Network Cards / component.modem.
- On first launch, the relay asks for a stable ID and display name, then saves
  them in /etc/nuclearcraft/reactor-relay.cfg.
- CLI values override and update the saved configuration, for example:
    reactor-relay --id=reactor-north --name="North Salt Reactor"
- The client uses a direct Linked Card immediately when present. Otherwise it
  discovers named relays over a Network Card, remembers the selected identity,
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
