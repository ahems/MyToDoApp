# Use an official Python runtime as a parent image - Debian 11
FROM python:3.12.3-bullseye

# Install v18 ODBC Driver for SQL Server for Debian 11
RUN curl https://packages.microsoft.com/keys/microsoft.asc | apt-key add - && \
    curl https://packages.microsoft.com/config/debian/11/prod.list > /etc/apt/sources.list.d/mssql-release.list && \
    apt-get update && \
    ACCEPT_EULA=Y apt-get install msodbcsql18 -y

# Set the working directory in the container to /app
WORKDIR /app

# Add current directory contents into the container at /app
ADD . /app

# Install any needed packages specified in requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Make port 80 available to the world outside this container
EXPOSE 80

# Setup an app user so the container doesn't run as the root user
RUN useradd app
USER app

# Run app.py when the container launches
CMD ["python", "app.py"]