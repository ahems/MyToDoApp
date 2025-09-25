# Use a parameterized Python base so you can easily target the latest stable
# Override at build time with --build-arg PYTHON_VERSION=3.13 --build-arg BASE_VARIANT=slim-bookworm
ARG PYTHON_VERSION=3.13
ARG BASE_VARIANT=slim-bookworm
FROM python:${PYTHON_VERSION}-${BASE_VARIANT}

# Set the working directory in the container to /app
WORKDIR /app

# Prevent Python from writing .pyc files and ensure stdout/stderr are unbuffered
ENV PYTHONDONTWRITEBYTECODE=1 \
	PYTHONUNBUFFERED=1

# Copy only requirements first to maximize layer caching
COPY requirements.txt /app/

# Install any needed packages specified in requirements.txt
RUN pip install --no-cache-dir --upgrade pip \
	&& pip install --no-cache-dir -r requirements.txt

# Now copy the rest of the app
COPY . /app

# Make port 80 available to the world outside this container
EXPOSE 80

# Run app.py when the container launches
CMD ["python", "app.py"]