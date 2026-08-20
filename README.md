# moonshine
## Containers, containers, containers

| image | what's in it | size |
|---|---|---|
| `moonshine-base:brush` | musl + brush as `/bin/sh`, no busybox | 7.92 MB |
| `moonshine-brush:latest` | brush alone, on `FROM scratch`, no libc at all | 6.06 MB |
| `moonshine-apk:latest` | the same, plus apk, so it can install packages | 14.3 MB |
| `moonshine-sway:latest` | sway on top of the apk image, no mesa at all | 93.9 MB |

brush is the only shell. There is no busybox, no ash, and by default no
coreutils either

## Build
```sh
make              # Every image
make test         # Run tests
make sizes        # Examine sizes
make shell        # brush in the base image
make brush-shell  # brush in a libc-free image
make sway-run     # start sway headless and print what it brought up
```

# Resources
