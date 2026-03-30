#!/usr/bin/env python3
"""
Generate two files of N-bit hex values for PSI benchmarking.

Each file contains one hex value per line. The sets share a controllable
number of common elements, plus unique elements for each party.
"""

# Example execution:
# uv run gen_hex_sets.py --bitlen 256 --shared 250 --server-only 750 --client-only 750

import argparse
import random


def gen_hex_sets(
    bitlen: int,
    n_shared: int,
    n_server_only: int,
    n_client_only: int,
    server_file: str,
    client_file: str,
    seed: int | None = None,
):
    if seed is not None:
        random.seed(seed)

    total_needed = n_shared + n_server_only + n_client_only
    hex_digits = (bitlen + 3) // 4  # nibbles needed to represent bitlen bits

    seen = set()
    pool = []
    while len(pool) < total_needed:
        v = random.getrandbits(bitlen)
        if v not in seen:
            seen.add(v)
            pool.append(v)

    shared       = pool[:n_shared]
    server_only  = pool[n_shared : n_shared + n_server_only]
    client_only  = pool[n_shared + n_server_only :]

    server_set = shared + server_only
    client_set = shared + client_only

    random.shuffle(server_set)
    random.shuffle(client_set)

    def write_set(path: str, values: list[int]):
        with open(path, "w") as f:
            for v in values:
                f.write(f"{v:0{hex_digits}x}\n")

    write_set(server_file, server_set)
    write_set(client_file, client_set)

    print(f"Server set : {len(server_set)} elements -> {server_file}")
    print(f"Client set : {len(client_set)} elements -> {client_file}")
    print(f"Shared     : {n_shared}")
    print(f"Bit length : {bitlen}  ({hex_digits} hex digits per line)")


def main():
    parser = argparse.ArgumentParser(
        description="Generate two files of N-bit hex values for PSI."
    )
    parser.add_argument("--bitlen", type=int, default=32,
                        help="Bit length of each element (default: 32)")
    parser.add_argument("--shared", type=int, default=10,
                        help="Number of elements present in both sets (default: 10)")
    parser.add_argument("--server-only", type=int, default=90,
                        help="Number of elements unique to the server set (default: 90)")
    parser.add_argument("--client-only", type=int, default=90,
                        help="Number of elements unique to the client set (default: 90)")
    parser.add_argument("--server-file", type=str, default="server_set.txt",
                        help="Output file for the server set (default: server_set.txt)")
    parser.add_argument("--client-file", type=str, default="client_set.txt",
                        help="Output file for the client set (default: client_set.txt)")
    parser.add_argument("--seed", type=int, default=None,
                        help="Random seed for reproducibility (default: none)")

    args = parser.parse_args()

    gen_hex_sets(
        bitlen=args.bitlen,
        n_shared=args.shared,
        n_server_only=args.server_only,
        n_client_only=args.client_only,
        server_file=args.server_file,
        client_file=args.client_file,
        seed=args.seed,
    )


if __name__ == "__main__":
    main()
