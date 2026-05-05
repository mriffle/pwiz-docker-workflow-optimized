# Plan: Rebuild the ProteoWizard container image with wine-devel from source

## Motivation

The published `proteowizard/pwiz-skyline-i-agree-to-the-vendor-licenses` image
(version 3.0.26120-bb3c999, container commit 489b8c0) has a regression: msconvert
and Skyline cannot correctly read input files that are symbolic links on the
host. The full diagnosis is in `wine-symlink-regression.txt` in this directory.
Short version: the regression is caused by the WineHQ branch switching from
`devel` to `staging` (the Wine version, 10.6, is fine). Wine-staging carries an
out-of-tree patchset (`patches/ntdll-Junction_Points/`) that makes path-based
file-metadata APIs (`GetFileAttributesEx`, `FindFirstFile`, etc.) report symlinks
as 0-byte files with the reparse-point flag set. Vendor SDKs that size buffers
from path metadata before opening fail. Mainline `wine-devel` does not carry that
patchset, so swapping the WineHQ branch fixes the bug.

We already shipped a quick fix as a *derived* image at:

- `mriffle/pwiz-skyline-i-agree-to-the-vendor-licenses:3.0.26120-bb3c999-fixed`
- `quay.io/protio/pwiz-skyline-i-agree-to-the-vendor-licenses:3.0.26120-bb3c999-fixed`

That image is `FROM proteowizard/...:latest` and apt-swaps wine-staging for
wine-devel at runtime, then runs `wineboot --update` at build time to normalize
the prefix. It works, but it has two sources of bloat:

1. The wine-staging files in `/usr` and the staging-era prefix files in
   `/wineprefix64` are shadowed (not deleted) by our new layers. They still
   consume space in the lower layers. ~1.59 GB layer for the apt swap.
2. `wineboot --update` rewrites most of the prefix's fake DLLs. ~1.65 GB layer.

Final size of the derived image: 9.99 GB vs upstream's 8.34 GB. The image works
correctly but ~1.65 GB is wasted on shadowed bytes.

A **fresh build from source** with `WINEDISTRO=devel` produces a clean image of
roughly upstream's size (~8.3 GB) with no shadowed cruft and no need for a
startup-time prefix update. This plan describes how to do that.

While we're rebuilding from source, we also prune `/wineprefix64/drive_c/pwiz`
to the parts our workflow uses: **Skyline, msconvert, and BlibBuild, with all
vendor formats supported.** This drops Skyline test caches, the bundled JRE
for Skyline's separate Java tools (EncyclopeDIA, BiblioSpec helpers), debug
symbols, Skyline's own test DLLs, and the pwiz CLI tools we don't run
(msaccess, msbenchmark, mscat, peakaboo, etc.). It does **not** drop any
vendor SDK DLLs. Expected savings: ~555 MB. Final image size estimate:
~7.7 GB (vs upstream ~8.3 GB and our derived image ~9.99 GB).

## Tradeoff to be aware of

The fresh build does not share layer blobs with `proteowizard/...:latest` on the
registries. Every layer hashes differently from upstream, so:

- On push, no cross-repo blob mounts. We upload the full image (~8 GB) ourselves.
- On pull, end users who have the upstream image cached do not get any
  deduplication benefit — they download the full image.

For the *derived* image we shipped earlier, layer sharing meant the actual
on-the-wire push/pull was only ~3.2 GB (everything below our two new layers
mounted from the upstream blob). A fresh build loses that benefit.

This tradeoff is acceptable here because:

- Disk size at rest is smaller (cleaner image with no shadowed bytes).
- No runtime `wineboot --update` work each launch (we already addressed this
  in the derived image too, but at a 1.65 GB layer cost).
- The image is genuinely a single-source build — easier to reason about and
  to maintain going forward.

## Inputs already available in this working directory

- `/home/mriffle/pwiz-symlink-fix/container/` — clone of
  https://github.com/ProteoWizard/container at the commit that produced the
  current published image (commit 489b8c0). Contains:
  - `container/Dockerfile` — final image build (lines 1–65). Two-stage: stage 0
    extracts pwiz/Skyline tarballs, stage 1 is `FROM
    proteowizard/wine-dotnet:winestaging10.6-net4.8-x64` and copies the
    extracted tree in.
  - `container/dotnet/Dockerfile` — builds the wine-dotnet base image. **Line
    37: `ENV WINEDISTRO=staging`.** This is the only file where the regression
    actually lives; flipping it to `devel` is the fix.
  - `container/mywine` — small wrapper script, copied to /usr/bin/mywine.
- `/home/mriffle/pwiz-symlink-fix/wine-symlink-regression.txt` — full
  empirical diagnosis of the bug, including verified end-to-end fix.
- `/home/mriffle/pwiz-symlink-fix/pwiz-fixed-build/Dockerfile` — the derived
  approach (already shipped). Reference, not used in this plan.
- The published upstream image is on disk:
  - Repo: `proteowizard/pwiz-skyline-i-agree-to-the-vendor-licenses`
  - Tag: `latest` (also tagged `3.0.26120-bb3c999`)
  - Digest: `sha256:7ecac062373732b14be83564b02cdc8c919b9748bc83dd8b71afca20d14d0535`
  - Built: 2026-05-01

## Inputs we need to obtain

The container build expects two binary artifacts in the build context that the
git repo does not contain — ProteoWizard's CI fetches them from TeamCity:

- `pwiz-bin-windows-*.tar.bz2` (pwiz Windows binaries)
- `SkylineTester.zip` (Skyline distribution)

We do not have direct access to TeamCity. **Get them by extracting the relevant
tree from the published image instead.** The published image already contains
exactly the version we want (3.0.26120-bb3c999) at `/wineprefix64/drive_c/pwiz`
— that path holds both the unpacked pwiz binaries *and* the unpacked Skyline
tree (under `pwiz/skyline/`).

```bash
docker create --name pwiz-extract \
    proteowizard/pwiz-skyline-i-agree-to-the-vendor-licenses:latest
docker cp pwiz-extract:/wineprefix64/drive_c/pwiz ./pwiz-artifacts
docker rm pwiz-extract
```

`./pwiz-artifacts/` will then contain the entire `pwiz` tree (including
`pwiz/skyline/`). We will COPY this directly in the modified Dockerfile,
skipping the original tarball-unpack stage.

## Plan

### Step 1: Modify `container/dotnet/Dockerfile`

Single line change at line 37:

```dockerfile
ENV WINEDISTRO=staging       # before
ENV WINEDISTRO=devel         # after
```

Leave `WINEVERSION=10.6~focal-1` and the `ubuntu:20.04` base unchanged. Leave
everything else in the file unchanged.

### Step 2: Build the wine-dotnet base

```bash
docker build -t local/wine-dotnet:winedevel10.6-net4.8-x64 container/dotnet/
```

Expected build time: 25–40 minutes. The slow step is `winetricks -q dotnet48`
in the final RUN of the Dockerfile (line 71). This runs the full .NET 4.8
installer under Wine and is genuinely lengthy. `winetricks -q vcrun2008
vcrun2017 corefonts` is also non-trivial but smaller.

The wineprefix is created natively under wine-devel, so no `wineboot --update`
is required afterward — the prefix matches the running Wine binary.

### Step 3: Extract and prune pwiz artifacts from the published image

See "Inputs we need to obtain" above for the extract command. Result is
`./pwiz-artifacts/` containing the unpacked pwiz + Skyline tree (~951 MB).

After extraction, prune the tree to the workflow we actually need:
**Skyline + msconvert + BlibBuild, all vendor formats supported.** This drops
~555 MB of test fixtures, bundled JRE, debug symbols, and unused pwiz CLI
tools. Run from the working directory:

```bash
# Drop Skyline test data caches (used only by Skyline's own test suite)
rm -rf ./pwiz-artifacts/skyline/CachedDownloadsForTests

# Drop Skyline's bundled JRE + EncyclopeDIA / BiblioSpec helper tools
# (separate Java-based Skyline tooling, not needed by Skyline itself,
# msconvert, or BlibBuild)
rm -rf ./pwiz-artifacts/skyline/Tools_CFTKIC31_en-US

# Drop debug symbols and Skyline's own test binaries
find ./pwiz-artifacts/skyline -maxdepth 1 -name '*.pdb'    -delete
find ./pwiz-artifacts/skyline -maxdepth 1 -name 'Test*.dll' -delete

# Drop pwiz CLI tools other than msconvert. BlibBuild lives under
# skyline/ and is preserved by the COPY of the skyline subtree, so the
# only tool we need to keep here is msconvert itself.
for tool in msaccess msbenchmark mscat msdiff msdir mspicture \
            peakaboo qtofpeakpicker txt2mzml chainsaw idconvert idcat \
            msistats pepcat pepsum seems MSConvertGUI; do
    rm -f ./pwiz-artifacts/${tool}.exe \
          ./pwiz-artifacts/${tool}.exe.config \
          ./pwiz-artifacts/${tool}.exe.manifest
done
```

**Do NOT prune any vendor SDK DLLs** in `pwiz-artifacts/` — the workflow
must support all vendor formats. That keeps the entire Bruker (`BDal.*`,
`baf2sql_c.dll`, `timsdata.dll`, etc.), Sciex (`Clearcore2.*`, `SCIEX.*`),
Waters (`MassLynxRaw.dll`, etc.), Agilent (`MIDAC.dll`, `BaseTof.dll`,
etc.), Shimadzu (`Shimadzu.LabSolutions.IO.*`, `MSMSDBCntl.dll`), and
Thermo (`ThermoFisher.CommonCore.*`) families intact. Leave
`ThermoRawMetaDump.exe` (~1.9 MB) and `sldout.exe` (~48 KB) alone — they
are vendor-specific debug tools that someone investigating a vendor issue
will want.

Expected size after prune: `du -sh ./pwiz-artifacts` should report ~395 MB
(down from ~951 MB). If it is much larger, something in the prune did not
match — investigate before continuing.

**Caveat — Skyline test DLL pruning is mildly speculative.** `Test.dll`,
`TestUtil.dll`, and `TestFunctional.dll` are conventionally test-only by
.NET naming, but Skyline could in principle reference one at runtime. The
Step 6 verification will catch any breakage; if Skyline-daily.exe fails to
start after the prune, restore those files from a fresh extract before
re-building.

### Step 4: Modify `container/Dockerfile`

Replace the two-stage build with a single-stage build that uses our local
wine-dotnet base and copies the pre-extracted artifacts. Specifically:

- **Delete lines 1–9** (the entire stage-0 builder that does
  `ubuntu:20.04` + `apt install unzip bzip2` + ADD tarball + ADD zip + unzip).
  We do not need it because we already have the unpacked tree on disk.
- **Change line 11** `FROM proteowizard/wine-dotnet:winestaging10.6-net4.8-x64`
  to `FROM local/wine-dotnet:winedevel10.6-net4.8-x64`.
- **Change line 12** `COPY --from=0 /wineprefix64/drive_c/pwiz
  /wineprefix64/drive_c/pwiz` to `COPY pwiz-artifacts/
  /wineprefix64/drive_c/pwiz/`.
- **Fix the unrelated `wine64_anyuser` bug at line 53.** Modern Wine merged
  wow64 — there is no `wine64` binary anymore, only `wine`. The default CMD
  `["wine64_anyuser", "msconvert"]` returns "sudo: wine64: command not found"
  on any wine 9.x+ image, including both the upstream image and our derived
  one. Change to `["wine_anyuser", "msconvert"]`. Note: line 32 already
  defines a working `wine_anyuser` script (without the 64), so no other
  change is needed.

Leave the LABELs, ENV WINEDEBUG, ENV WINEPATH, sudo setup, galaxy users,
WORKDIR, mywine ADD, the apptainer TMP fix, and everything else untouched.

### Step 5: Build the final image

From the working directory (where `container/` and `pwiz-artifacts/` both
sit), run:

```bash
docker build -t pwiz-fresh-devel:latest -f container/Dockerfile .
```

Expected build time: 1–3 minutes (just file copies; no apt or winetricks).
Expected final image size: ~7.7 GB (post-prune).

### Step 6: Verify before pushing

#### Verify the symlink fix

The Win32 metadata probe (`probe.exe`) used in the original verification lives
under `wine-symlink-test/` (see `wine-symlink-regression.txt` for build
recipe). Quick smoke test using the existing fixture in the working directory:

```bash
mkdir -p /tmp/symlink-test
printf 'HELLO\n' > /tmp/symlink-test/target.txt
ln -sf target.txt /tmp/symlink-test/link.txt

docker run --rm -v /tmp/symlink-test:/data pwiz-fresh-devel:latest \
    wine_anyuser cmd /v:on /c 'for %f in (Z:\data\link.txt) do @echo %~zf'
```

Expected output: `6` (the size of "HELLO\n"). If output is `0`, the fix did
not take and the build is wrong.

#### Verify a real Thermo .raw via symlink

The working directory contains `088_Ecl-2026-03-22_PfizerExp_15r2_60m_DIA.raw`
(real file) and `symlink.raw` (symlink to it). Run msconvert against the
symlink:

```bash
docker run --rm -v "$(pwd)":/data pwiz-fresh-devel:latest \
    wine_anyuser msconvert /data/symlink.raw -o /data/out
```

Expected: completes successfully, produces an mzML output with the same
content as `088_Ecl-2026-03-22_PfizerExp_15r2_60m_DIA.mzML` (also in working
dir, the known-good reference).

#### Verify Skyline still launches after the prune

Smoke test that pruning Skyline test DLLs / bundled JRE / debug symbols
did not break Skyline-daily itself:

```bash
docker run --rm pwiz-fresh-devel:latest \
    wine_anyuser /wineprefix64/drive_c/pwiz/skyline/Skyline-daily.exe \
    --help 2>&1 | head -20
```

Expected: prints Skyline command-line help, no missing-DLL errors. If you
see `FileLoadException` / `FileNotFoundException` referencing `Test*.dll`,
restore those files from a fresh extract and rebuild.

Also smoke-test BlibBuild:

```bash
docker run --rm pwiz-fresh-devel:latest \
    wine_anyuser /wineprefix64/drive_c/pwiz/skyline/BlibBuild.exe 2>&1 | head -10
```

Expected: prints BlibBuild usage / missing-args message, not a load error.

#### Verify startup is fast (no `wineboot --update` running)

```bash
time docker run --rm pwiz-fresh-devel:latest wine_anyuser msconvert --help \
    >/dev/null
```

There should be no `rundll32.exe ... setupapi.dll,InstallHinfSection` process
during startup, and total time should be roughly comparable to the original
upstream (staging) image. If it is markedly slower than upstream, the prefix
is not in the expected state and step 2 needs investigation.

### Step 7: Tag and push

The earlier *derived* fix is currently published at the
`3.0.26120-bb3c999-fixed` tag on both registries. **Decision point: do we
overwrite that tag with this fresh build, or use a new tag?**

Two reasonable options:

- **Overwrite**: same tag, replace the derived image with the fresh one.
  Anyone pulling `...:3.0.26120-bb3c999-fixed` gets the cleaner build. Risk:
  pulls in flight may resolve to the old digest briefly. Acceptable for a
  small user base.
- **New tag**: e.g. `3.0.26120-bb3c999-fixed-clean` or `-rebuild`. Keeps the
  derived image accessible for comparison. Slightly more registry storage.

Confirm the tagging choice with the user before pushing. Once decided:

```bash
docker tag pwiz-fresh-devel:latest \
    mriffle/pwiz-skyline-i-agree-to-the-vendor-licenses:<chosen-tag>
docker tag pwiz-fresh-devel:latest \
    quay.io/protio/pwiz-skyline-i-agree-to-the-vendor-licenses:<chosen-tag>

docker push mriffle/pwiz-skyline-i-agree-to-the-vendor-licenses:<chosen-tag>
docker push quay.io/protio/pwiz-skyline-i-agree-to-the-vendor-licenses:<chosen-tag>
```

These pushes will be slower than the previous derived push because no layers
will be mounted from upstream — every layer is genuinely new.

## Things to NOT do

- Do not modify `container/Dockerfile` lines 22–24 (ENV WINEDEBUG, ENV
  WINEPATH) or the LABELs. These match upstream and there is no reason to
  change them.
- Do not skip `wineserver -w` after winetricks invocations in the dotnet
  Dockerfile — those barriers exist to flush prefix state before the next
  step.
- Do not switch the base image from `ubuntu:20.04` (focal). WineHQ still
  publishes wine-devel for focal at 10.6~focal-1. There is no reason to bump
  base in this plan; doing so would change far more than just the WineHQ
  branch.
- Do not run `wineboot --update` after building. The prefix is created
  natively under wine-devel — it does not need an update. (This is the whole
  point of building from source instead of derived: we skip that 1.65 GB
  layer entirely.)
- Do not use `--squash` or `docker-squash`. We are not building on top of
  upstream so there is nothing to squash; the layers we produce are already
  the minimum.

## Rollback

If anything goes wrong, the derived image at
`mriffle/pwiz-skyline-i-agree-to-the-vendor-licenses:3.0.26120-bb3c999-fixed`
(and the corresponding Quay tag) is the previously verified known-good fix.
Pull it back, retag, and re-push. The local image still exists as
`pwiz-fixed-devel:latest` (id `3f9bedad5fc5`).
