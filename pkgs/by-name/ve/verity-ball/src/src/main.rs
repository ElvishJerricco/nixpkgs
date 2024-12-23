use std::path::PathBuf;
use fs_verity::FsVeritySha256;
use sha2::Digest;
use std::io;
use tar::{Archive, Builder, EntryType};
use anyhow::{Context, Result};
use std::os::unix::ffi::OsStrExt;

fn main() -> Result<()> {
    let mut input = Archive::new(io::stdin());
    let mut output = Builder::new(io::stdout());

    // Note: This loop is easier with 'input.entries()?.raw(true)'.
    // In that case, we can simply 'append_data' every entry as it
    // was. But that prevents us from getting full paths, which are
    // needed for 'trusted.overlay.redirect'. Without raw, we have to
    // take a little extra care around symlinks, see below. There are
    // probably other edge cases here, but nothing that would come up
    // in the nix store.
    for file in input.entries()? {
        let mut file = file?;

        // Write overlayfs xattrs
        match file.header().entry_type() {
            EntryType::Regular => {
                let mut d = FsVeritySha256::new();
                io::copy(&mut file, &mut d)?;

                // We should use algo to determine params. For now hard code sha256
                // let algo = d.inner_hash_algorithm();
                // 00240001: 0x00 version, 0x24 size, 0x00 flags, 0x01 sha256
                // f"setfattr -n trusted.overlay.metacopy -v 0x00240001{digest} $file",

                let digest = d.finalize();
                let metacopy = [&[0x00, 0x24, 0x00, 0x01], digest.as_slice()].concat();
                let mut pb = PathBuf::from("/");
                pb.push(file.path()?);
                
                output.append_pax_extensions(vec![
                    ("SCHILY.xattr.trusted.overlay.metacopy", metacopy.as_slice()),
                    ("SCHILY.xattr.trusted.overlay.redirect", pb.as_os_str().as_bytes()),
                ])?
            },
            EntryType::Directory => output.append_pax_extensions(vec![
                ("SCHILY.xattr.trusted.overlay.opaque", b"y".as_slice()),
            ])?,
            _ => {},
        }

        // Write the entry data.
        // For regular files, this is intentionally omitted so they can be meta-only.
        let mut header = file.header().clone();
        let path = file.path()?.into_owned();
        match file.header().entry_type() {
            EntryType::Regular => output.append_data(&mut header, path, [].as_slice())?,
            EntryType::Symlink => output.append_link(&mut header, path, file.link_name()?.context("no link found")?)?,
            _ => output.append_data(&mut header, path, file)?,
        }
    }
    output.finish()?;
    Ok(())
}
