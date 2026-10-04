# sysmon-bar

A small macOS menu bar item showing CPU load and memory used (`⌗ 23%  ▤ 10.4G`). Clicking it opens a panel with:

- **CPU**: total load with a history graph, user/system split, load averages, and for every core its
  load and average clock, grouped into performance and efficiency cores.
- **Memory**: used of total with a history graph, and the split into app, wired, compressed, cached
  and free memory, memory pressure and swap.

It samples every 2 seconds (`sampleInterval` in `App.swift`).

## Where the numbers come from

| | Source |
|---|---|
| Core load | `host_processor_info` tick counters, as in Activity Monitor |
| Core clock | IOReport's `CPU Core Performance States` residencies, weighted by the DVFS frequency tables of the `pmgr` device (`voltage-states1-sram` for E-cores, `voltage-states5-sram` for P-cores). Apple Silicon only, no root needed |
| Memory | `host_statistics64`, counted like Activity Monitor: used = app (anonymous − purgeable) + wired + compressed; cached = file-backed + purgeable |
| Swap, pressure | `vm.swapusage`, `kern.memorystatus_vm_pressure_level` |

A core's clock is its average frequency while it was not idle during the last interval; cores
idle throughout show `idle`. libIOReport is private API and may change between macOS releases;
if it is missing, the panel just hides the clocks.

## Install

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`); no Xcode project.

```sh
./install.sh            # build ~/Applications/SysMon.app and start it at login
./install.sh uninstall  # remove the app and its LaunchAgent
```

`~/Applications/SysMon.app/Contents/MacOS/SysMon --dump` prints one sample and exits.

## License

[MIT](LICENSE)
