NuclearCraft OpenComputers monitor scripts

Shared libraries
- nuclearcraft.ui contains the common client theme, metric formatting, scrolling views,
  dashboard refresh loop, drawing, and response handling.
- nuclearcraft.rpc provides linked-card and modem endpoints for serialized
  request/response traffic.
- OPPM installs the required libraries with each client or server package.

reactor-server.lua / reactor-client.lua
- Salt fission reactor + Geiger counter.
- Uses Linked Cards / component.tunnel for the cross-dimensional link.
- Reactor server normalizes NuclearCraft 2.19a getVesselStats() data.
- Client has compact scrollable views and a live auto-refresh dashboard.

heat-server.lua / heat-client.lua
- NuclearCraft heat exchanger.
- Uses normal OpenComputers Network Cards / component.modem.
- Port: 48722
- Server interprets getExchangerTubeStats() and getCondensationTubeStats().
- Client has compact scrollable views and a live auto-refresh dashboard.
- Client/server check component.isAvailable("modem") before accessing component.modem.
