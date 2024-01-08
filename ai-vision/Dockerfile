FROM python:3.10

# Set the working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && \
    apt-get install -y libgl1-mesa-glx && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy the local src directory contents to the working directory
COPY . /app

# Install any dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Expose port 5000 for the application.
EXPOSE 5000

# Start the application.
CMD ["gunicorn", "-b", "0.0.0.0:5000", "app:app"]
