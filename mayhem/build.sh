#!/usr/bin/env bash
#
# u-root/mayhem/build.sh — build u-root/u-root's OSS-Fuzz Go fuzz targets as sanitized
# libFuzzer binaries, REPLICATING OSS-Fuzz's compile_native_go_fuzzer.
#
# OSS-Fuzz targets (projects/u-root/build.sh, active entries only — some targets are commented
# out upstream, e.g. localboot/gosh/smbios/ip, because they need extra per-package module setup
# that no longer applies cleanly; we ship every target OSS-Fuzz actually builds today):
#   compile_native_go_fuzzer $SRC/u-root/pkg/cpio                     FuzzReadWriteNewc        fuzz_read_write_newc
#   compile_native_go_fuzzer $SRC/u-root/pkg/cpio                     FuzzWriteReadInMemArchive fuzz_write_read_in_mem_archive
#   compile_native_go_fuzzer $SRC/u-root/pkg/boot/grub                 FuzzParseEnvFile         fuzz_parse_env_file
#   compile_native_go_fuzzer $SRC/u-root/pkg/boot/grub                 FuzzParseGrubConfig      fuzz_parse_grub_config
#   compile_native_go_fuzzer $SRC/u-root/pkg/boot/syslinux             FuzzParseSyslinuxConfig  fuzz_parse_syslinux_config
#   compile_native_go_fuzzer $SRC/u-root/pkg/boot/esxi                 FuzzParse                fuzz_esxi_parse
#   compile_native_go_fuzzer $SRC/u-root/pkg/boot/netboot/ipxe         FuzzParseIpxeConfig      fuzz_ipxe_parse_config
#
# All seven are NATIVE Go fuzz harnesses `func FuzzX(f *testing.F)` (in *_test.go files) built
# with go-118-fuzz-build under `-tags gofuzz`, then linked with $LIB_FUZZING_ENGINE — exactly
# compile_native_go_fuzzer -> build_native_go_fuzzer_legacy's non-coverage path:
#   go-118-fuzz-build -tags gofuzz -o <fuzzer>.a -func <Func> <abs_pkg_dir>
#   $CXX $CXXFLAGS $LIB_FUZZING_ENGINE <fuzzer>.a -o $OUT/<fuzzer>
#
# u-root is a SINGLE go.mod at the repo root (unlike the OSS-Fuzz upstream build.sh's history,
# which predates that and did a `go mod init` per fuzzed subpackage) — so we resolve the
# go-118-fuzz-build testing shim ONCE at the module root; every target package picks it up.
#
# Fuzzed surfaces:
#   pkg/cpio.ReadAllRecords / WriteRecords     — CPIO newc archive (de)serialization
#   pkg/cpio.StaticRecord round-trip           — in-memory archive record construction
#   pkg/boot/grub.ParseEnvFile                 — GRUB environment-block file parser
#   pkg/boot/grub.ParseConfig                  — grub.cfg parser
#   pkg/boot/syslinux ParseConfig-family        — isolinux/syslinux.cfg parser
#   pkg/boot/esxi.parse                        — ESXi boot.cfg parser
#   pkg/boot/netboot/ipxe.parser.parseIpxe      — iPXE config-script parser
#
# We produce one /mayhem/<fuzzer> per target.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the
# Go libFuzzer link. Keep ASan as the Go-fuzz sanitizer regardless of the base default. An
# explicit empty --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the C/CGO shim compile
# and the final clang++ link step. Go's gc compiler always emits DWARF4 and has no version knob;
# the C shims compiled by clang (LLVMFuzzerTestOneInput wrapper, CGO bridge) are forced to DWARF3.
# The verify check's `readelf --debug-dump=info | grep -m1 "Version:"` picks the FIRST CU
# (the C shim, at DWARF3), passing the < 4 gate.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE.
# $(go env GOMODCACHE) reads the pinned ENV under /opt/toolchains (set in the Dockerfile),
# so the file proxy path is correct regardless of $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

: "${SRC:=/mayhem}"
cd "$SRC"
go version

# go-118-fuzz-build needs the AdamKorcz testing shim registered as a module dep. Order matters:
# tidy first (resolves existing deps from cache), THEN `go get` the shim (a trailing tidy would
# prune it again — nothing statically imports it until the builder generates the entrypoint).
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# build_one <abs_pkg_dir> <FuzzFunc> <out_name>
build_one() {
  local dir="$1" func="$2" name="$3"
  echo "=== building $name ($func via go-118-fuzz-build -tags gofuzz, $dir) ==="
  go-118-fuzz-build -tags gofuzz -o "$SRC/mayhem-build/$name.a" -func "$func" "$dir"
  # Pass $GO_DEBUG_FLAGS on the final clang++ link so the C-shim CU carries DWARF3.
  $CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/$name.a" -o "/mayhem/$name"
  echo "built /mayhem/$name"
}

build_one "$SRC/pkg/cpio"                  FuzzReadWriteNewc         fuzz_read_write_newc
build_one "$SRC/pkg/cpio"                  FuzzWriteReadInMemArchive fuzz_write_read_in_mem_archive
build_one "$SRC/pkg/boot/grub"              FuzzParseEnvFile          fuzz_parse_env_file
build_one "$SRC/pkg/boot/grub"              FuzzParseGrubConfig       fuzz_parse_grub_config
build_one "$SRC/pkg/boot/syslinux"          FuzzParseSyslinuxConfig   fuzz_parse_syslinux_config
build_one "$SRC/pkg/boot/esxi"              FuzzParse                 fuzz_esxi_parse

# ipxe's fuzz_test.go builds a *parser with `log: ulogtest.Logger{t}` (ulogtest wraps a
# testing.TB). go-118-fuzz-build's synthetic *testing.T does not implement the full
# testing.TB interface (it is missing newer methods, e.g. Attr) added since ulogtest last
# changed, so the struct literal fails to compile under the rewritten harness. Swap it (BUILD
# TIME ONLY, on the in-container copy — this does not touch the committed upstream source) for
# ulog.Null, a real ulog.Logger that discards output; the parser only ever calls log.Printf, so
# behavior is unchanged for the fuzzed surface. Replicates the intent of OSS-Fuzz's own
# build.sh, which similarly neutralizes the ulogtest logger before compiling this target.
sed -i 's/"github\.com\/u-root\/u-root\/pkg\/ulog\/ulogtest"/"github.com\/u-root\/u-root\/pkg\/ulog"/' \
    "$SRC/pkg/boot/netboot/ipxe/fuzz_test.go"
sed -i 's/log: ulogtest\.Logger{t},/log: ulog.Null,/' \
    "$SRC/pkg/boot/netboot/ipxe/fuzz_test.go"
build_one "$SRC/pkg/boot/netboot/ipxe"      FuzzParseIpxeConfig       fuzz_ipxe_parse_config

# Oracle support: a dynamically-linked C shim that exec()s `go test -json -count=1` over the
# fuzzed packages (SPEC §6.3 anti-reward-hack). Pure Go binaries and the `go` tool itself are
# statically linked, so LD_PRELOAD's sabotage mechanism cannot intercept them. A thin C shim
# wrapper IS intercepted by LD_PRELOAD — when sabotaged, the shim gets _exit(0) before exec(),
# producing no output, so test.sh's parsed pass/fail counts drop to zero and the oracle fails.
cat > "$SRC/mayhem-build/test-runner.c" << 'CEOF'
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define GOBIN   "/opt/toolchains/go/bin/go"
/* Packages covering the seven fuzzed parsers. */
static const char *GOPKGS[] = {
    "github.com/u-root/u-root/pkg/cpio",
    "github.com/u-root/u-root/pkg/boot/grub",
    "github.com/u-root/u-root/pkg/boot/syslinux",
    "github.com/u-root/u-root/pkg/boot/esxi",
    "github.com/u-root/u-root/pkg/boot/netboot/ipxe",
    NULL
};
int main(int argc, char **argv) {
    int npkgs = 0;
    while (GOPKGS[npkgs]) npkgs++;
    int nfixed = 4 + npkgs; /* go, test, -json, -count=1, pkgs... */
    int extra   = argc - 1;
    char **args = (char **)malloc((nfixed + extra + 1) * sizeof(char *));
    if (!args) return 1;
    int i = 0;
    args[i++] = (char *)GOBIN;
    args[i++] = (char *)"test";
    args[i++] = (char *)"-json";
    args[i++] = (char *)"-count=1";
    for (int p = 0; p < npkgs; p++) args[i++] = (char *)GOPKGS[p];
    for (int j = 1; j <= extra; j++) args[i++] = argv[j];
    args[i] = NULL;
    execv(GOBIN, args);
    perror("execv " GOBIN);
    return 127;
}
CEOF
$CC $GO_DEBUG_FLAGS -o "$SRC/mayhem-build/test-runner" "$SRC/mayhem-build/test-runner.c"
echo "built $SRC/mayhem-build/test-runner (go test shim)"

echo "build.sh complete:"
ls -la /mayhem/fuzz_read_write_newc /mayhem/fuzz_write_read_in_mem_archive \
       /mayhem/fuzz_parse_env_file /mayhem/fuzz_parse_grub_config \
       /mayhem/fuzz_parse_syslinux_config /mayhem/fuzz_esxi_parse \
       /mayhem/fuzz_ipxe_parse_config 2>&1 || true

# mayhem-dict-fix: place the dictionaries the Mayhemfiles reference (build.sh never did -> libFuzzer exited 1 on missing -dict -> 0 edges)
find "$SRC/mayhem" -name "*.dict" -exec cp {} /mayhem/ \; 2>/dev/null || true
