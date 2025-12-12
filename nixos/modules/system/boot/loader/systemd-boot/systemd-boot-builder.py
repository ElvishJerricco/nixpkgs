#! @python3@/bin/python3 -B
import argparse
import ctypes
import datetime
import errno
import os
import re
import shutil
import subprocess
import sys
import tempfile
import warnings
import json
from typing import NamedTuple, Any, Sequence
from dataclasses import dataclass
from pathlib import Path

# These values will be replaced with actual values during the package build
BOOTSPEC_TOOLS = "@bootspecTools@"
DISTRO_NAME = "@distroName@"
NIX = "@nix@"
SYSTEMD = "@systemd@"


@dataclass
class Config:
    efi_sys_mount_point: Path
    boot_mount_point: Path
    nixos_dir: Path  # Path relative to the XBOOTLDR or ESP mount point
    timeout: str
    editor: bool
    console_mode: str
    configuration_limit: int
    reboot_for_bitlocker: bool
    can_touch_efi_variables: bool
    graceful: bool
    copy_extra_files: str
    check_mountpoints: str
    store_dir: str

    def loader_conf(self) -> Path:
        return (
            self.efi_sys_mount_point / "loader/loader.conf"
        )  # Always stored on the ESP


@dataclass
class BootSpec:
    init: Path
    initrd: Path
    kernel: Path
    kernelParams: list[str]  # noqa: N815
    label: str
    system: str
    toplevel: Path
    specialisations: dict[str, "BootSpec"]
    sortKey: str  # noqa: N815
    devicetree: Path | None = None  # noqa: N815
    initrdSecrets: str | None = None  # noqa: N815


libc = ctypes.CDLL("libc.so.6")

FILE = None | int


def run(
    cmd: Sequence[str | Path], stdout: FILE = None
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=True, text=True, stdout=stdout)


class SystemIdentifier(NamedTuple):
    profile: str | None
    generation: int
    specialisation: str | None


def copy_if_not_exists(source: Path, dest: Path) -> None:
    if not dest.exists():
        tmpfd, tmppath = tempfile.mkstemp(
            dir=dest.parent, prefix=dest.name, suffix=".tmp."
        )
        shutil.copyfile(source, tmppath)
        os.fsync(tmpfd)
        shutil.move(tmppath, dest)


def generation_dir(profile: str | None, generation: int) -> Path:
    if profile:
        return Path(
            f"/nix/var/nix/profiles/system-profiles/{profile}-{generation}-link"
        )
    else:
        return Path(f"/nix/var/nix/profiles/system-{generation}-link")


def system_dir(
    profile: str | None, generation: int, specialisation: str | None
) -> Path:
    d = generation_dir(profile, generation)
    if specialisation:
        return d / "specialisation" / specialisation
    else:
        return d


BOOT_ENTRY = """title {title}
sort-key {sort_key}
version Generation {generation} {description}
linux {kernel}
initrd {initrd}
options {kernel_params}
"""


def generation_conf_filename(
    profile: str | None, generation: int, specialisation: str | None
) -> str:
    pieces = [
        "nixos",
        profile or None,
        "generation",
        str(generation),
        f"specialisation-{specialisation}" if specialisation else None,
    ]
    return "-".join(p for p in pieces if p) + ".conf"


def write_loader_conf(
    cfg: Config, profile: str | None, generation: int, specialisation: str | None
) -> None:
    tmp = cfg.loader_conf().with_suffix(".tmp")
    with tmp.open("x") as f:
        f.write(f"timeout {cfg.timeout}\n")
        f.write(
            "default %s\n"
            % generation_conf_filename(profile, generation, specialisation)
        )
        if not cfg.editor:
            f.write("editor 0\n")
        if cfg.reboot_for_bitlocker:
            f.write("reboot-for-bitlocker yes\n")
        f.write(f"console-mode {cfg.console_mode}\n")
        f.flush()
        os.fsync(f.fileno())
    os.rename(tmp, cfg.loader_conf())


def get_bootspec(profile: str | None, generation: int) -> BootSpec:
    system_directory = system_dir(profile, generation, None)
    boot_json_path = (system_directory / "boot.json").resolve()
    if boot_json_path.is_file():
        with boot_json_path.open("r") as f:
            # check if json is well-formed, else throw error with filepath
            try:
                bootspec_json = json.load(f)
            except ValueError as e:
                print(
                    f"error: Malformed Json: {e}, in {boot_json_path}", file=sys.stderr
                )
                sys.exit(1)
    else:
        boot_json_str = run(
            [
                f"{BOOTSPEC_TOOLS}/bin/synthesize",
                "--version",
                "1",
                system_directory,
                "/dev/stdout",
            ],
            stdout=subprocess.PIPE,
        ).stdout
        bootspec_json = json.loads(boot_json_str)
    return bootspec_from_json(bootspec_json)


def bootspec_from_json(bootspec_json: dict[str, Any]) -> BootSpec:
    specialisations = bootspec_json["org.nixos.specialisation.v1"]
    specialisations = {k: bootspec_from_json(v) for k, v in specialisations.items()}
    systemdBootExtension = bootspec_json.get("org.nixos.systemd-boot", {})
    sortKey = systemdBootExtension.get("sortKey", "nixos")
    devicetree = systemdBootExtension.get("devicetree")

    if devicetree:
        devicetree = Path(devicetree)

    main_json = bootspec_json["org.nixos.bootspec.v1"]
    for attr in ("kernel", "initrd", "toplevel"):
        if attr in main_json:
            main_json[attr] = Path(main_json[attr])
    return BootSpec(
        **main_json,
        specialisations=specialisations,
        sortKey=sortKey,
        devicetree=devicetree,
    )


def copy_from_file(cfg: Config, file: Path, dry_run: bool = False) -> Path:
    """
    Copy a file to the boot filesystem (XBOOTLDR if in use, otherwise ESP), basing the destination filename on the store path that's being copied from. Return the destination path, relative to the boot filesystem mountpoint.
    """
    store_file_path = file.resolve()
    suffix = store_file_path.name
    store_subdir = store_file_path.relative_to(cfg.store_dir).parts[0]
    efi_file_path = cfg.nixos_dir / (
        f"{suffix}.efi" if suffix == store_subdir else f"{store_subdir}-{suffix}.efi"
    )
    if not dry_run:
        copy_if_not_exists(store_file_path, cfg.boot_mount_point / efi_file_path)
    return efi_file_path


def write_entry(
    cfg: Config,
    profile: str | None,
    generation: int,
    specialisation: str | None,
    machine_id: str | None,
    bootspec: BootSpec,
    current: bool,
) -> None:
    if specialisation:
        bootspec = bootspec.specialisations[specialisation]
    kernel = copy_from_file(cfg, bootspec.kernel)
    initrd = copy_from_file(cfg, bootspec.initrd)
    devicetree = (
        copy_from_file(cfg, bootspec.devicetree)
        if bootspec.devicetree is not None
        else None
    )

    title = "{name}{profile}{specialisation}".format(
        name=DISTRO_NAME,
        profile=" [" + profile + "]" if profile else "",
        specialisation=" (%s)" % specialisation if specialisation else "",
    )

    try:
        if bootspec.initrdSecrets is not None:
            run([bootspec.initrdSecrets, cfg.boot_mount_point / initrd])
    except subprocess.CalledProcessError:
        if current:
            print("failed to create initrd secrets!", file=sys.stderr)
            sys.exit(1)
        else:
            print(
                "warning: failed to create initrd secrets "
                f'for "{title} - Configuration {generation}", an older generation',
                file=sys.stderr,
            )
            print(
                "note: this is normal after having removed "
                "or renamed a file in `boot.initrd.secrets`",
                file=sys.stderr,
            )
    entry_file = (
        cfg.boot_mount_point
        / "loader/entries"
        / generation_conf_filename(profile, generation, specialisation)
    )
    tmp_path = entry_file.with_suffix(".tmp")
    kernel_params = "init=%s " % bootspec.init

    kernel_params = kernel_params + " ".join(bootspec.kernelParams)
    build_time = int(system_dir(profile, generation, specialisation).stat().st_ctime)
    build_date = datetime.datetime.fromtimestamp(build_time).strftime("%F")

    with tmp_path.open("w") as f:
        f.write(
            BOOT_ENTRY.format(
                title=title,
                sort_key=bootspec.sortKey,
                generation=generation,
                kernel=f"/{kernel}",
                initrd=f"/{initrd}",
                kernel_params=kernel_params,
                description=f"{bootspec.label}, built on {build_date}",
            )
        )
        if machine_id is not None:
            f.write("machine-id %s\n" % machine_id)
        if devicetree is not None:
            f.write(f"devicetree /{devicetree}\n")
        f.flush()
        os.fsync(f.fileno())
    tmp_path.rename(entry_file)


def get_generations(cfg: Config, profile: str | None = None) -> list[SystemIdentifier]:
    gen_list = run(
        [
            f"{NIX}/bin/nix-env",
            "--list-generations",
            "-p",
            "/nix/var/nix/profiles/%s"
            % ("system-profiles/" + profile if profile else "system"),
        ],
        stdout=subprocess.PIPE,
    ).stdout
    gen_lines = gen_list.split("\n")
    gen_lines.pop()

    configurationLimit = cfg.configuration_limit
    configurations = [
        SystemIdentifier(
            profile=profile, generation=int(line.split()[0]), specialisation=None
        )
        for line in gen_lines
    ]
    return configurations[-configurationLimit:]


def remove_old_entries(cfg: Config, gens: list[SystemIdentifier]) -> None:
    rex_profile = re.compile(r"^nixos-(.*)-generation-.*\.conf$")
    rex_generation = re.compile(
        r"^nixos.*-generation-([0-9]+)(-specialisation-.*)?\.conf$"
    )
    known_paths = []
    for gen in gens:
        bootspec = get_bootspec(gen.profile, gen.generation)
        known_paths.append(copy_from_file(cfg, bootspec.kernel, True).name)
        known_paths.append(copy_from_file(cfg, bootspec.initrd, True).name)
        if bootspec.devicetree is not None:
            known_paths.append(copy_from_file(cfg, bootspec.devicetree, True).name)
    for path in (cfg.boot_mount_point / "loader/entries").glob(
        "nixos*-generation-[1-9]*.conf", case_sensitive=False
    ):
        if rex_profile.match(path.name):
            prof = rex_profile.sub(r"\1", path.name)
        else:
            prof = None
        try:
            gen_number = int(rex_generation.sub(r"\1", path.name))
        except ValueError:
            continue
        if (prof, gen_number, None) not in gens:
            path.unlink()
    for path in (cfg.boot_mount_point / cfg.nixos_dir).iterdir():
        if path.name not in known_paths and not path.is_dir():
            path.unlink()


def cleanup_esp(cfg: Config) -> None:
    for path in (cfg.efi_sys_mount_point / "loader/entries").glob("nixos*"):
        path.unlink()
    nixos_dir = cfg.efi_sys_mount_point / cfg.nixos_dir
    if nixos_dir.is_dir():
        shutil.rmtree(nixos_dir)


def get_profiles() -> list[str]:
    system_profiles = Path("/nix/var/nix/profiles/system-profiles/")
    if system_profiles.is_dir():
        return [
            x.name for x in system_profiles.iterdir() if not x.name.endswith("-link")
        ]
    else:
        return []


def install_bootloader(cfg: Config, args: argparse.Namespace) -> None:
    try:
        with open("/etc/machine-id") as machine_file:
            machine_id = machine_file.readlines()[0].strip()
    except IOError as e:
        if e.errno != errno.ENOENT:
            raise
        machine_id = None

    if os.getenv("NIXOS_INSTALL_GRUB") == "1":
        warnings.warn(
            "NIXOS_INSTALL_GRUB env var deprecated, use NIXOS_INSTALL_BOOTLOADER",
            DeprecationWarning,
        )
        os.environ["NIXOS_INSTALL_BOOTLOADER"] = "1"

    # flags to pass to bootctl install/update
    bootctl_flags = []

    if cfg.boot_mount_point != cfg.efi_sys_mount_point:
        bootctl_flags.append(f"--boot-path={cfg.boot_mount_point}")

    if not cfg.can_touch_efi_variables:
        bootctl_flags.append("--no-variables")

    if cfg.graceful:
        bootctl_flags.append("--graceful")

    if os.getenv("NIXOS_INSTALL_BOOTLOADER") == "1":
        # bootctl uses fopen() with modes "wxe" and fails if the file exists.
        cfg.loader_conf().unlink(missing_ok=True)

        run(
            [f"{SYSTEMD}/bin/bootctl", f"--esp-path={cfg.efi_sys_mount_point}"]
            + bootctl_flags
            + ["install"]
        )
    else:
        # Update bootloader to latest if needed
        available_out = run(
            [f"{SYSTEMD}/bin/bootctl", "--version"], stdout=subprocess.PIPE
        ).stdout.split()[2]
        installed_out = run(
            [
                f"{SYSTEMD}/bin/bootctl",
                f"--esp-path={cfg.efi_sys_mount_point}",
                "status",
            ],
            stdout=subprocess.PIPE,
        ).stdout

        # See status_binaries() in systemd bootctl.c for code which generates this
        # Matches
        # Available Boot Loaders on ESP:
        #  ESP: /boot (/dev/disk/by-partuuid/9b39b4c4-c48b-4ebf-bfea-a56b2395b7e0)
        # File: └─/EFI/systemd/systemd-bootx64.efi (systemd-boot 255.2)
        # But also:
        # Available Boot Loaders on ESP:
        #  ESP: /boot (/dev/disk/by-partuuid/9b39b4c4-c48b-4ebf-bfea-a56b2395b7e0)
        # File: ├─/EFI/systemd/HashTool.efi
        #       └─/EFI/systemd/systemd-bootx64.efi (systemd-boot 255.2)
        installed_match = re.search(
            r"^\W+.*/EFI/(?:BOOT|systemd)/.*\.efi \(systemd-boot ([\d.]+[^)]*)\)$",
            installed_out,
            re.IGNORECASE | re.MULTILINE,
        )

        available_match = re.search(r"^\((.*)\)$", available_out)

        if installed_match is None:
            raise Exception(
                "Could not find any previously installed systemd-boot. If you are switching to systemd-boot from a different bootloader, you need to run `nixos-rebuild switch --install-bootloader`"
            )

        if available_match is None:
            raise Exception("could not determine systemd-boot version")

        installed_version = installed_match.group(1)
        available_version = available_match.group(1)

        if installed_version < available_version:
            print(
                "updating systemd-boot from %s to %s"
                % (installed_version, available_version),
                file=sys.stderr,
            )
            run(
                [f"{SYSTEMD}/bin/bootctl", f"--esp-path={cfg.efi_sys_mount_point}"]
                + bootctl_flags
                + ["update"]
            )

    (cfg.boot_mount_point / cfg.nixos_dir).mkdir(parents=True, exist_ok=True)
    (cfg.boot_mount_point / "loader/entries").mkdir(parents=True, exist_ok=True)

    gens = get_generations(cfg)
    for profile in get_profiles():
        gens += get_generations(cfg, profile)

    remove_old_entries(cfg, gens)

    for gen in gens:
        try:
            bootspec = get_bootspec(gen.profile, gen.generation)
            is_default = Path(bootspec.init).parent == Path(args.default_config)
            write_entry(cfg, *gen, machine_id, bootspec, current=is_default)
            for specialisation in bootspec.specialisations.keys():
                write_entry(
                    cfg,
                    gen.profile,
                    gen.generation,
                    specialisation,
                    machine_id,
                    bootspec,
                    current=is_default,
                )
            if is_default:
                write_loader_conf(cfg, *gen)
        except OSError as e:
            # See https://github.com/NixOS/nixpkgs/issues/114552
            if e.errno == errno.EINVAL:
                profile = (
                    f"profile '{gen.profile}'" if gen.profile else "default profile"
                )
                print(
                    "ignoring {} in the list of boot entries because of the following error:\n{}".format(
                        profile, e
                    ),
                    file=sys.stderr,
                )
            else:
                raise e

    if cfg.boot_mount_point != cfg.efi_sys_mount_point:
        # Cleanup any entries in ESP if xbootldrMountPoint is set.
        # If the user later unsets xbootldrMountPoint, entries in XBOOTLDR will not be cleaned up
        # automatically, as we don't have information about the mount point anymore.
        cleanup_esp(cfg)

    extra_files_dir = cfg.boot_mount_point / cfg.nixos_dir / ".extra-files"
    for root, _, files in extra_files_dir.walk(top_down=False):
        relative_root = root.relative_to(extra_files_dir)
        actual_root = cfg.boot_mount_point / relative_root

        for file in files:
            actual_file = actual_root / file
            actual_file.unlink(missing_ok=True)
            (root / file).unlink()

        if not list(actual_root.iterdir()):
            actual_root.rmdir()
        root.rmdir()

    extra_files_dir.mkdir(parents=True, exist_ok=True)

    run([cfg.copy_extra_files])


def main() -> None:
    parser = argparse.ArgumentParser(
        description=f"Update {DISTRO_NAME}-related systemd-boot files"
    )
    parser.add_argument(
        "builder_config",
        metavar="BUILDER-CONFIG",
        help="The JSON config file to configure the builder",
    )
    parser.add_argument(
        "default_config",
        metavar="DEFAULT-CONFIG",
        help=f"The default {DISTRO_NAME} config to boot",
    )
    args = parser.parse_args()

    with Path(args.builder_config).open("r") as f:
        builder_config_json = json.load(f)

    builder_config_json["efi_sys_mount_point"] = Path(
        builder_config_json["efi_sys_mount_point"]
    )
    builder_config_json["boot_mount_point"] = Path(
        builder_config_json["boot_mount_point"]
    )
    builder_config_json["nixos_dir"] = Path(builder_config_json["nixos_dir"].strip("/"))

    # TODO: This is not type-checking the arguments
    cfg = Config(**builder_config_json)
    print(cfg, file=sys.stderr)

    run([cfg.check_mountpoints])

    try:
        install_bootloader(cfg, args)
    finally:
        # Since fat32 provides little recovery facilities after a crash,
        # it can leave the system in an unbootable state, when a crash/outage
        # happens shortly after an update. To decrease the likelihood of this
        # event sync the efi filesystem after each update.
        rc = libc.syncfs(os.open(f"{cfg.boot_mount_point}", os.O_RDONLY))
        if rc != 0:
            print(
                f"could not sync {cfg.boot_mount_point}: {os.strerror(rc)}",
                file=sys.stderr,
            )

        if cfg.boot_mount_point != cfg.efi_sys_mount_point:
            rc = libc.syncfs(os.open(cfg.efi_sys_mount_point, os.O_RDONLY))
            if rc != 0:
                print(
                    f"could not sync {cfg.efi_sys_mount_point}: {os.strerror(rc)}",
                    file=sys.stderr,
                )


if __name__ == "__main__":
    main()
