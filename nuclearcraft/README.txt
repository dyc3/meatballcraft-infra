NuclearCraft OpenComputers monitor scripts

Shared libraries
- nuclearcraft.ui contains the common client theme, metric formatting, scrolling views,
  dashboard refresh loop, drawing, and response handling.
- nuclearcraft.rpc provides linked-card and modem endpoints for serialized
  request/response traffic.
- OPPM installs the required libraries with each client or server package.

geiger-server.lua / geiger-client.lua
- Standalone Geiger counter monitor with no reactor dependency.
- Uses Linked Cards / component.tunnel for the cross-dimensional link.
- Displays chunk radiation in Rads/t with SI prefixes.
- Client has a compact reading view and a live auto-refresh dashboard.

reactor-server.lua / reactor-relay.lua / reactor-client.lua
- Salt fission reactor + Geiger counter.
- The server uses a Linked Card for the cross-dimensional link to the relay.
- The relay serves clients over normal Network Cards / component.modem.
- Port: 48723
- Reactor server normalizes NuclearCraft 2.19a getVesselStats() data.
- Client has compact scrollable views and a live auto-refresh dashboard.

heat-server.lua / heat-client.lua
- NuclearCraft heat exchanger.
- Uses normal OpenComputers Network Cards / component.modem.
- Port: 48722
- Server interprets getExchangerTubeStats() and getCondensationTubeStats().
- Client has compact scrollable views and a live auto-refresh dashboard.
- Client/server check component.isAvailable("modem") before accessing component.modem.
