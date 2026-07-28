#!/usr/bin/env rust-script

use std::process::Command;

fn main() {
    let path_output = Command::new("/usr/bin/which")
        .arg("macmon")
        .output()
        .expect("cannot execute /usr/bin/which");
    assert!(path_output.status.success(), "macmon is not on PATH");
    let path = String::from_utf8(path_output.stdout).expect("macmon path is not UTF-8");

    let version_output = Command::new("macmon")
        .arg("--version")
        .output()
        .expect("cannot execute macmon");
    assert!(version_output.status.success(), "macmon --version failed");
    let version = String::from_utf8(version_output.stdout).expect("macmon version is not UTF-8");

    println!("{}\t{}", path.trim(), version.trim());
}
