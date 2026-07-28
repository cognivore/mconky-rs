#!/usr/bin/env rust-script

use std::io::{self, Write};
use std::thread;
use std::time::Duration;

unsafe extern "C" {
    fn getpid() -> i32;
    fn getppid() -> i32;
    fn getpgrp() -> i32;
}

fn main() {
    let (pid, ppid, pgid) = unsafe { (getpid(), getppid(), getpgrp()) };
    println!("pid={pid} ppid={ppid} pgid={pgid}");
    io::stdout().flush().expect("cannot flush process-group probe output");
    thread::sleep(Duration::from_millis(1_500));
}
