MeatballCraft Service Discovery
===============================

meatball.discovery finds named services on an OpenComputers modem network.
Discovery probes are broadcast on port 48700. Matching providers send offers
directly to the requesting Network Card. Applications then use the returned
address and servicePort for unicast traffic.

Linked Cards are not part of service discovery.

Provider example:

  local discovery = require("meatball.discovery")
  local handle, err = discovery.advertise(component.modem, {
    serviceType = "example.status",
    instanceId = "status-north",
    displayName = "North Status Server",
    apiVersion = 1,
    servicePort = 49000,
    metadata = { zone = "north" }
  })
  assert(handle, err)

Consumer example:

  local services, err = discovery.find(component.modem, {
    serviceType = "example.status",
    apiVersion = 1,
    timeout = 1
  })
  assert(services, err)

Each result contains serviceType, instanceId, displayName, apiVersion,
servicePort, address, metadata, lastSeen, and conflict. A conflict means the
same instanceId was offered from more than one modem address; callers should
not silently choose between conflicting results.

advertise returns a handle. Call handle.close() to stop answering probes. The
library reference-counts its use of port 48700 and does not close a port that
was already open before discovery began.

The complete design and protocol proposal is in design-proposal.html.
