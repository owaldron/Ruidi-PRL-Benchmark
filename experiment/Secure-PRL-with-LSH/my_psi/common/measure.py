import os
import subprocess
from random import random, seed, randint
from datetime import datetime
from subprocess import Popen, PIPE
from time import sleep
from os import remove, killpg, getpgid
from signal import SIGTERM
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FuturesTimeoutError
import sys


def read_and_delete_file(fname):
    f = open(fname, 'r')
    line1 = f.readline()
    time = line1.split()[1]
    line2 = f.readline()
    cpu_time = line2.split()[1]
    line3 = f.readline()
    comp = line3.split()[1]
    f.close()
    remove(fname)
    return time, cpu_time, comp

def experiment(num_eles, num_bins, out, srv_seed=10, cli_seed=100, num_bits=16):
    # subprocess.run("./my_psi", "-r", 0, "-n", num_eles, "-b", num_bits, "-m", num_bins, "-s", seed)
    timeout_s = 60*15

    process0 = None
    process1 = None
    try:
        process0 = Popen([str(x) for x in ['./my_psi', "-r", 0, "-n", num_eles, "-b", num_bits, "-m", num_bins, "-s", srv_seed, "-f", "server_set.txt"]], stdout=PIPE, stderr=PIPE)
        process1 = Popen([str(x) for x in ['./my_psi', "-r", 1, "-n", num_eles, "-b", num_bits, "-m", num_bins, "-s", cli_seed, "-f", "client_set.txt"]], stdout=PIPE, stderr=PIPE)

        # Communicate with both processes concurrently so neither blocks waiting
        # for the other to connect/finish
        with ThreadPoolExecutor(max_workers=2) as ex:
            f0 = ex.submit(process0.communicate)
            f1 = ex.submit(process1.communicate)
            try:
                stdout_data, stderr_data = f0.result(timeout=timeout_s)
                f1.result(timeout=timeout_s)
            except FuturesTimeoutError:
                raise subprocess.TimeoutExpired(cmd='my_psi', timeout=timeout_s)

        # Popen returns bytes, so decode it to a standard string
        cout = stdout_data.decode('utf-8')
        cerr = stderr_data.decode('utf-8')
    except subprocess.TimeoutExpired:
        if process0 is not None:
            killpg(getpgid(process0.pid), SIGTERM)
        if process1 is not None:
            killpg(getpgid(process1.pid), SIGTERM)
        return

    # if the output files don't exist, it means the experiment failed (e.g., due to a timeout or crash), so we skip reading results
    if not (os.path.exists(f"0{srv_seed}.txt") and os.path.exists(f"1{cli_seed}.txt")):
        print("C implementation was unsuccessful!", flush=True)
        print(f"Server output: \n{cout}", flush=True)
        print(f"Server error: \n{cerr}", flush=True)
        return

    srv_time, srv_cpu_time, srv_comp = read_and_delete_file(f"0{srv_seed}.txt")
    cli_time, cli_cpu_time, cli_comp = read_and_delete_file(f"1{cli_seed}.txt")

    time = round((float(srv_time) + float(cli_time)) / 2, 4)

    print(f"neles: {num_eles},\tnbins: {num_bins},\ttime: {time},\tsrv cpu time: {srv_cpu_time},\tcli cpu time: {cli_cpu_time}\tcomp: {srv_comp}", flush=True)

    out.write(f"{num_eles}, {num_bins}, {time}, {srv_cpu_time}, {cli_cpu_time}, {srv_comp}\n")


# Ensure the script receives the output file argument from my_test.sh
if len(sys.argv) < 2:
    print("Usage: python3 measure.py <output_directory>")
    sys.exit(1)

out_dir = sys.argv[1]
out_filename = f"{out_dir}/results.csv"

# Seed the PRNG using the output path string. 
# This ensures deterministic, reproducible seeds tied to the specific RUN_KEY.
seed(out_filename)

# Initialize the output file (this creates it or clears an existing one)
with open(out_filename, 'w') as outfile:
    outfile.write("num_eles, num_bins, time, srv_cpu_time, cli_cpu_time, comp\n")

count = 1
NUM_RUNS = 10

for run in range(NUM_RUNS):
    print(f"start measuring run #{run}")

    for num_eles in [1000]:
        for num_bins in [8]:
            
            # Generate deterministic seeds based on the initial string seed
            s_seed = randint(1, 500) * 10 + count
            c_seed = randint(501, 1000) * 10 + count
            
            print("========================================")
            print(f"#{run}: server seed {s_seed} and client seed {c_seed}")
            sleep(1)
            
            try:
                # Open in append mode for the experiment execution
                with open(out_filename, 'a') as outfile:
                    experiment(num_eles, num_bins, outfile, srv_seed=s_seed, cli_seed=c_seed, num_bits=256)
            except Exception as e:
                print(f"An exception occurred with server seed {s_seed} and client seed {c_seed}: {e}")
                # Log the specific failure for debugging
                with open(f'{out_dir}/failed_{num_eles}eles_{num_bins}bins.txt', 'w') as fail:
                    fail.write(f"Failed with exception: {e}\n")
            
            count += 1