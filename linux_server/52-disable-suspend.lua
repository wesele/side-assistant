table.insert(bluez_monitor.rules, {
  matches = {
    {
      { "node.name", "matches", "bluez_input.*" },
    },
    {
      { "node.name", "matches", "bluez_output.*" },
    },
  },
  apply_properties = {
    ["session.suspend-timeout-seconds"] = 0,
  },
})
