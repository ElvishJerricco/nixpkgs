#![deny(clippy::all)]

use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::os::unix;
use std::path::{Path, PathBuf};
use walkdir::WalkDir;

#[derive(Deserialize)]
struct Config {
    systemd_package: PathBuf,
    type_dir: String,
    upstream_units: BTreeSet<String>,
    upstream_wants: BTreeSet<String>,
    packages: BTreeSet<PathBuf>,
    allow_collisions: bool,
    autodetect_units: BTreeSet<PathBuf>,
    dropin_units: BTreeSet<PathBuf>,
    unit_aliases: BTreeMap<String, BTreeSet<String>>,
    units_wanted_by: BTreeMap<String, BTreeSet<String>>,
    units_upheld_by: BTreeMap<String, BTreeSet<String>>,
    units_required_by: BTreeMap<String, BTreeSet<String>>,
    system_dependencies: Option<SystemDependencies>,
}

#[derive(Deserialize)]
struct SystemDependencies {
    default_unit: String,
    ctrl_alt_del_unit: String,
}

fn copy_or_create_link(source: &Path, destination: &Path) -> Result<()> {
    let meta = source
        .symlink_metadata()
        .with_context(|| format!("Checking file info: {source:?}"))?;
    let target = if meta.is_symlink() {
        &fs::read_link(source).with_context(|| format!("Reading symlink: {source:?}"))?
    } else {
        source
    };
    unix::fs::symlink(target, destination)
        .with_context(|| format!("Creating symlink: {destination:?}"))?;
    Ok(())
}

fn lndir(source: &Path, destination: &Path) -> Result<()> {
    for dirent in WalkDir::new(source) {
        let dirent = dirent.with_context(|| format!("Reading directory entry from: {source:?}"))?;
        if dirent.depth() == 0 {
            // Do nothing on root
            continue;
        }

        let inner_source = dirent.path();
        (|| {
            let inner_destination = &destination.join(inner_source.strip_prefix(source)?);
            if dirent.file_type().is_dir() {
                Ok(fs::create_dir(inner_destination)?)
            } else {
                copy_or_create_link(inner_source, inner_destination)
            }
        })()
        .with_context(|| format!("Creating lndir child for: {inner_source:?}"))?;
    }
    Ok(())
}

fn install_upstream_unit(
    upstream_unit_dir: &Path,
    upstream_unit: &str,
    out_dir: &Path,
) -> Result<()> {
    copy_or_create_link(
        &upstream_unit_dir.join(upstream_unit),
        &out_dir.join(upstream_unit),
    )
    .with_context(|| format!("Installing upstream unit: {upstream_unit}"))?;
    Ok(())
}

// TODO: It's not clear that we strictly need to copy these `wants`
// directories. We might just be able to symlink the directory directly.
fn install_upstream_want(
    upstream_unit_dir: &Path,
    upstream_want: &str,
    out_dir: &Path,
) -> Result<()> {
    let out_wants_dir = &out_dir.join(upstream_want);
    let upstream_wants_dir = &upstream_unit_dir.join(upstream_want);
    fs::create_dir_all(out_wants_dir)
        .with_context(|| format!("Creating directory: {out_wants_dir:?}"))?;
    for dirent in fs::read_dir(upstream_wants_dir)
        .with_context(|| format!("Reading directory: {upstream_wants_dir:?}"))?
    {
        let dirent = dirent
            .with_context(|| format!("Reading directory entry from: {upstream_wants_dir:?}"))?;
        let source = &dirent.path();
        let destination = &out_wants_dir.join(dirent.file_name());
        if dirent.file_type()?.is_symlink() {
            let target =
                fs::read_link(source).with_context(|| format!("Reading symlink: {source:?}"))?;

            // Joining the target to the output directory will resolve
            // to the same path as resolving a symlink within the out
            // directory that has that target. This works whether the
            // target is relative or absolute, because joining an
            // absolute path replaces the original.
            if out_wants_dir.join(&target).exists() {
                unix::fs::symlink(&target, destination)
                    .with_context(|| format!("Creating symlink: {destination:?}"))?;
            }
        } else {
            fs::copy(source, destination)
                .with_context(|| format!("Copying: {source:?} -> {destination:?}"))?;
        }
    }
    Ok(())
}

fn install_package(package_unit_dir: &Path, out_dir: &Path) -> Result<()> {
    for dirent in fs::read_dir(package_unit_dir)
        .with_context(|| format!("Reading directory: {package_unit_dir:?}"))?
    {
        let dirent = dirent
            .with_context(|| format!("Reading directory entry from: {package_unit_dir:?}"))?;
        if dirent.path().extension() != Some(OsStr::new("wants")) {
            let out_name = &out_dir.join(dirent.file_name());
            if dirent.file_type()?.is_dir() {
                fs::create_dir_all(out_name)
                    .with_context(|| format!("Creating directory: {out_name:?}"))?;
                lndir(&dirent.path(), out_name)?;
            } else {
                unix::fs::symlink(dirent.path(), out_name)
                    .with_context(|| format!("Creating symlink: {out_name:?}"))?;
            }
        }
    }
    Ok(())
}

fn make_overrides(unit_file: &Path, unit_name: &OsStr, out_dir: &Path) -> Result<()> {
    let mut buf = out_dir.to_path_buf();
    buf.push(unit_name);
    buf.add_extension("d");
    fs::create_dir(&buf).with_context(|| format!("Creating directory: {buf:?}"))?;
    buf.push("overrides.conf");
    unix::fs::symlink(unit_file, &buf).with_context(|| format!("Creating symlink: {buf:?}"))?;
    Ok(())
}

fn unit_file_details(unit_dir: &Path) -> Result<(PathBuf, OsString)> {
    let mut iter =
        fs::read_dir(unit_dir).with_context(|| format!("Reading directory: {unit_dir:?}"))?;
    let autodetect_unit_file = iter
        .next()
        // Option -> Result
        .with_context(|| format!("Empty directory: {unit_dir:?}"))?
        // Error reading dirent
        .with_context(|| format!("Reading directory entry from: {unit_dir:?}"))?;
    if iter.next().is_some() {
        bail!("Directory had more than one file: {unit_dir:?}");
    }
    Ok((
        autodetect_unit_file.path(),
        autodetect_unit_file.file_name(),
    ))
}

fn install_autodetect_unit(
    allow_collisions: bool,
    autodetect_unit_dir: &Path,
    out_dir: &Path,
) -> Result<()> {
    let (autodetect_unit_path, autodetect_unit_name) = unit_file_details(autodetect_unit_dir)?;

    let out_file = &out_dir.join(&autodetect_unit_name);
    if out_file.exists() {
        if fs::canonicalize(&autodetect_unit_path)
            .with_context(|| format!("Canonicalizing: {autodetect_unit_path:?}"))?
            == Path::new("/dev/null")
        {
            fs::remove_file(out_file)?;
            unix::fs::symlink("/dev/null", out_file)?;
        } else if allow_collisions {
            make_overrides(&autodetect_unit_path, &autodetect_unit_name, out_dir)?;
        } else {
            bail!("Found multiple derivations configuring {autodetect_unit_name:?}");
        }
    } else {
        unix::fs::symlink(&autodetect_unit_path, out_file)
            .with_context(|| format!("Creating symlink: {out_file:?}"))?;
    }

    Ok(())
}

fn install_dropin_unit(dropin_unit: &Path, out_dir: &Path) -> Result<()> {
    let (dropin_unit_path, dropin_unit_name) = unit_file_details(dropin_unit)?;
    make_overrides(&dropin_unit_path, &dropin_unit_name, out_dir)
}

fn install_aliases(unit: &str, aliases: &BTreeSet<String>, out_dir: &Path) -> Result<()> {
    for alias in aliases {
        let alias_path = out_dir.join(alias);
        if alias_path.exists() {
            fs::remove_file(&alias_path)
                .with_context(|| format!("Removing file: {alias_path:?}"))?;
        }
        unix::fs::symlink(unit, &alias_path)
            .with_context(|| format!("Creating alias: {alias_path:?}"))?;
    }
    Ok(())
}

fn install_dependency(
    unit: &str,
    dep_type: &str,
    dependents: &BTreeSet<String>,
    out_dir: &Path,
) -> Result<()> {
    for dependent in dependents {
        let mut destination = out_dir.to_path_buf();
        destination.push(dependent);
        destination.add_extension(dep_type);
        if !destination.exists() {
            fs::create_dir(&destination)
                .with_context(|| format!("Creating directory: {destination:?}"))?;
        }
        destination.push(unit);
        let mut source = PathBuf::from("..");
        source.push(unit);
        if destination.exists() {
            fs::remove_file(&destination)
                .with_context(|| format!("Removing file: {destination:?}"))?;
        }
        unix::fs::symlink(&source, &destination)
            .with_context(|| format!("Creating symlink: {destination:?}"))?;
    }
    Ok(())
}

fn install_system_dependencies(
    system_dependencies: &SystemDependencies,
    out_dir: &Path,
) -> Result<()> {
    install_aliases(
        &system_dependencies.default_unit,
        &BTreeSet::from(["default.target".to_owned()]),
        out_dir,
    )?;
    install_aliases(
        &system_dependencies.ctrl_alt_del_unit,
        &BTreeSet::from(["ctrl-alt-del.target".to_owned()]),
        out_dir,
    )?;
    install_dependency(
        "remote-fs.target",
        "wants",
        &BTreeSet::from(["multi-user.target".to_owned()]),
        out_dir,
    )?;
    Ok(())
}

fn parse_args() -> Result<(Config, PathBuf)> {
    let mut args: Vec<String> = env::args().collect();
    let name = args.remove(0);
    match &args[..] {
        [cfg_path, out_path] => {
            let cfg: Config = serde_json::from_slice(
                &fs::read(cfg_path).with_context(|| format!("Reading config: {}", cfg_path))?,
            )
            .with_context(|| format!("Parsing JSON from: {}", cfg_path))?;
            let out_dir = PathBuf::from(out_path);
            Ok((cfg, out_dir))
        }
        _ => bail!("Usage: {name} <CONFIG> <OUTPUT>"),
    }
}

fn main() -> Result<()> {
    let (cfg, out_dir) = parse_args()?;

    let upstream_unit_dir = cfg
        .systemd_package
        .join("example/systemd")
        .join(&cfg.type_dir);

    fs::create_dir_all(&out_dir).with_context(|| format!("Creating directory: {out_dir:?}"))?;

    for upstream_unit in &cfg.upstream_units {
        install_upstream_unit(&upstream_unit_dir, upstream_unit, &out_dir)?;
    }

    for upstream_want in &cfg.upstream_wants {
        install_upstream_want(&upstream_unit_dir, upstream_want, &out_dir)?;
    }

    for package in &cfg.packages {
        for tree in ["etc", "lib"] {
            let package_units_dir = package.join(tree).join("systemd").join(&cfg.type_dir);
            if package_units_dir.exists() {
                install_package(&package_units_dir, &out_dir)?;
            }
        }
    }

    for autodetect_unit_dir in &cfg.autodetect_units {
        install_autodetect_unit(cfg.allow_collisions, autodetect_unit_dir, &out_dir)?;
    }

    for dropin_unit in &cfg.dropin_units {
        install_dropin_unit(dropin_unit, &out_dir)?;
    }

    for (unit, aliases) in &cfg.unit_aliases {
        install_aliases(unit, aliases, &out_dir)?;
    }

    for (unit, wanted_by) in &cfg.units_wanted_by {
        install_dependency(unit, "wants", wanted_by, &out_dir)?;
    }
    for (unit, upheld_by) in &cfg.units_upheld_by {
        install_dependency(unit, "upholds", upheld_by, &out_dir)?;
    }
    for (unit, required_by) in &cfg.units_required_by {
        install_dependency(unit, "requires", required_by, &out_dir)?;
    }

    if let Some(system_dependencies) = cfg.system_dependencies {
        install_system_dependencies(&system_dependencies, &out_dir)?;
    }

    Ok(())
}
