//! The egress proxy's entrypoint: generates each caller network's smokescreen policy
//! from the local config and supervises one smokescreen per network.

pub mod cli;
pub mod config;
pub mod drift;
pub mod facts;
pub mod files;
pub mod health;
pub mod plan;
pub mod policy;
pub mod render;
pub mod supervise;
