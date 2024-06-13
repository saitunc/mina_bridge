pub mod field;
pub mod merkle_path;
pub mod serialize;

use merkle_path::MerkleTree;
use serialize::EVMSerializable;
use std::fs;
use std::io::Write;

/// Reads input JSON file, deserializes it to `MerkleTree`, and writes the `MerklePath` to a binary file.
///
/// # Arguments
///
/// * `rpc_url` - The URL of the Mina node GraphQL API.
/// * `public_key_path` - A string slice that holds the path to the public key used to query the Mina node.
/// * `leaf_hash_path` - A string slice that holds the path to the output leaf hash file.
/// * `merkle_tree_path` - A string slice that holds the path to the output Merkle tree file.
///
/// # Errors
///
/// Returns a string slice with an error message if the file cannot be opened,
/// the content cannot be deserialized to JSON,
/// or the output file cannot be created or written to.
pub fn process_input_json(
    rpc_url: &str,
    public_key_path: &str,
    leaf_hash_path: &str,
    merkle_tree_path: &str,
) -> Result<(), String> {
    let public_key = std::fs::read_to_string(public_key_path)
        .map_err(|err| format!("Error opening file {err}"))?;
    let merkle_tree = MerkleTree::query_merkle_path(rpc_url, &public_key)?;

    let leaf_hash = field::from_str(&merkle_tree.data.account.leaf_hash)
        .map_err(|err| format!("Error deserializing leaf hash to field {err}"))?;

    let mut leaf_hash_file = fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(leaf_hash_path)
        .map_err(|err| format!("Error creating file {err}"))?;

    let _ = leaf_hash_file
        .write_all(&field::to_bytes(&leaf_hash)?)
        .map_err(|err| format!("Error writing to output file {err}"));

    let mut merkle_tree_file = fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(merkle_tree_path)
        .map_err(|err| format!("Error creating file {err}"))?;

    merkle_tree_file
        .write_all(&merkle_tree.data.account.merkle_path.to_bytes())
        .map_err(|err| format!("Error writing to output file {err}"))
}