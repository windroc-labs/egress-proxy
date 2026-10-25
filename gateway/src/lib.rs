//! The egress gateway's entrypoint: generates each caller network's smokescreen policy
//! from the local config and supervises one smokescreen per network.

pub mod config;
