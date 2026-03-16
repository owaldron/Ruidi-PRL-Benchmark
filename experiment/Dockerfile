# Build stage
# syntax=docker/dockerfile:1
FROM --platform=linux/amd64 debian:bookworm AS builder
WORKDIR /usr/src/app

# Install build dependencies for ABY and Python
RUN apt-get update && \
    apt-get install -y git cmake g++ make libgmp-dev libssl-dev libboost-all-dev python3 && \
    rm -rf /var/lib/apt/lists/*

# Clone the ABY framework
RUN git clone https://github.com/encryptogroup/ABY.git

# Copy the custom psi source code into the ABY examples directory
COPY --exclude="**/*.py" Secure-PRL-with-LSH/my_psi /usr/src/app/ABY/src/examples/my_psi

# Append the new subdirectory to the ABY examples CMakeLists.txt
RUN echo 'add_subdirectory(my_psi)' >> /usr/src/app/ABY/src/examples/CMakeLists.txt

# Configure and build the ABY project (including the new my_psi example)
WORKDIR /usr/src/app/ABY/build
RUN cmake .. -DABY_BUILD_EXE=On && make -j$(nproc)

# Run stage
FROM --platform=linux/amd64 debian:bookworm-slim

# Install runtime dependencies: Python3, AWS CLI, hardware utilities, and required shared libraries
RUN apt-get update && \
    apt-get install -y ca-certificates awscli util-linux python3 libgmp10 libgmpxx4ldbl libssl3 && \
    rm -rf /var/lib/apt/lists/*

# Set up the execution directory
WORKDIR /app/bin

# Copy the compiled binaries from the builder stage
COPY --from=builder /usr/src/app/ABY/build/bin /app/bin

# Copy the Python scripts into the bin directory as requested
COPY Secure-PRL-with-LSH/my_psi/common/gen.py /app/bin/gen.py
COPY Secure-PRL-with-LSH/my_psi/common/measure.py /app/bin/measure.py

# Generate the input datasets (inp0, inp1) during the image build
RUN python3 gen.py

# Move back to the main app directory for the orchestration scripts
WORKDIR /app

# Copy orchestration scripts
COPY collect_hardware.sh /app/collect_hardware.sh
COPY my_test.sh /app/my_test.sh

# Make the scripts executable
RUN chmod +x /app/collect_hardware.sh /app/my_test.sh

# my_test.sh orchestrates: hardware collection -> experiment -> S3 upload
ENTRYPOINT ["/app/my_test.sh"]