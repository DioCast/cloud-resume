variable "project_id" {
  description = "The ID of the Google Cloud project"
  type        = string
  default     = "dio-castillo-cloud"
}

variable "domain_name" {
  description = "The domain name for the website"
  type        = string
  default     = "resume.dio-castillo.cloud"
}

# 1. Setup the Google Provider
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = "us-west1"
}

# ==============================================================================
# FRONTEND: WEBSITE BUCKET & LOAD BALANCER
# ==============================================================================

# 1. Create the Bucket for the Website
resource "google_storage_bucket" "website" {
  name          = "${var.project_id}-public"
  location      = "US"
  uniform_bucket_level_access = true
  
  # Ensure we serve index.html when people visit
  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }
  force_destroy = true
}

# 2. Make the Bucket Public (Required for the Load Balancer to read it)
resource "google_storage_bucket_iam_member" "public_rule" {
  bucket = google_storage_bucket.website.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# 3. Reserve a Static IP Address (So your IP doesn't change)
resource "google_compute_global_address" "website_ip" {
  name = "website-lb-ip"
}

# 4. Create the Managed SSL Certificate (HTTPS)
resource "google_compute_managed_ssl_certificate" "website_ssl" {
  name = "website-ssl-cert-resume"
  managed {
    domains = [var.domain_name]
  }
  
  # THIS IS THE FIX:
  # It tells Terraform: "Create the new replacement BEFORE destroying the old one."
  lifecycle {
    create_before_destroy = true
  }
}

# 5. Create the Backend Bucket (Connects LB to Storage)
resource "google_compute_backend_bucket" "website_backend" {
  name        = "website-backend"
  bucket_name = google_storage_bucket.website.name
  enable_cdn  = true
}

# 6. Create the URL Map (Routes traffic to the backend)
resource "google_compute_url_map" "website_map" {
  name            = "website-url-map"
  default_service = google_compute_backend_bucket.website_backend.id
}

# 7. Create the HTTPS Proxy (Terminates SSL)
resource "google_compute_target_https_proxy" "website_proxy" {
  name             = "website-https-proxy"
  url_map          = google_compute_url_map.website_map.id
  ssl_certificates = [google_compute_managed_ssl_certificate.website_ssl.id]
}

# 8. Create the Forwarding Rule (The Front Door)
resource "google_compute_global_forwarding_rule" "default" {
  name       = "website-forwarding-rule"
  target     = google_compute_target_https_proxy.website_proxy.id
  port_range = "443"
  ip_address = google_compute_global_address.website_ip.id
}

# ==============================================================================
# BACKEND: API & DATABASE (Visitor Counter)
# ==============================================================================

# 1. Enable Services
resource "google_project_service" "firestore" {
  service            = "firestore.googleapis.com"
  disable_on_destroy = false
}
resource "google_project_service" "cloud_functions" {
  service            = "cloudfunctions.googleapis.com"
  disable_on_destroy = false
}
resource "google_project_service" "cloud_build" {
  service            = "cloudbuild.googleapis.com"
  disable_on_destroy = false
}
resource "google_project_service" "compute" {
  service            = "compute.googleapis.com" # Required for Load Balancer
  disable_on_destroy = false
}
# NEW: Required for storing the function's build image
resource "google_project_service" "artifact_registry" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

# 2. Create Firestore Database
resource "google_firestore_database" "database" {
  name        = "(default)"
  location_id = "us-west1" # Keeping it close to your region
  type        = "FIRESTORE_NATIVE"
  depends_on  = [google_project_service.firestore]
}

# 3. Create Function Source Bucket (Private)
resource "google_storage_bucket" "function_bucket" {
  name                        = "${var.project_id}-function-source"
  location                    = "US"
  uniform_bucket_level_access = true
}

# 4. Zip and Upload Code
data "archive_file" "source_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../api"
  output_path = "${path.module}/function.zip"
}

resource "google_storage_bucket_object" "zip_file" {
  name   = "source-${data.archive_file.source_zip.output_md5}.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = data.archive_file.source_zip.output_path
}

# 5. Security Scrub: Robot Access
data "google_project" "project" {}

# ------------------------------------------------------------------------------
# FIX: THE ARTIFACT REGISTRY BLOCKADE
# The build needs to save the "Cache Image" to pkg.dev, but lacks permission.
# We grant 'Admin' so it can create/write to the repo.
# ------------------------------------------------------------------------------
resource "google_project_iam_member" "artifact_registry_admin" {
  project = var.project_id
  role    = "roles/artifactregistry.admin"
  member  = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

# ------------------------------------------------------------------------------
# FIX: UN-GAG THE ROBOT (Allow it to write build logs)
# ------------------------------------------------------------------------------
resource "google_project_iam_member" "compute_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

# ------------------------------------------------------------------------------
# FIX: REMOVE THE BLINDFOLD (Log Access)
# Grants permission to view Logs and Error Reporting
# ------------------------------------------------------------------------------
resource "google_project_iam_member" "log_viewer" {
  project = var.project_id
  role    = "roles/logging.viewer"
  member  = "group:gcp-admins@dimarc-solutions.com"
}

# Optional: Grant Project Editor if you want to be able to click "Fix" in the console
resource "google_project_iam_member" "project_editor" {
  project = var.project_id
  role    = "roles/editor"
  member  = "group:gcp-admins@dimarc-solutions.com"
}

# ------------------------------------------------------------------------------
# FIX FOR ERROR 13 (ROOT CAUSE): Grant the "Legacy Robot" access
# Gen 1 functions often use this specific robot to fetch code.
# ------------------------------------------------------------------------------
resource "google_storage_bucket_iam_member" "app_engine_reader" {
  bucket = google_storage_bucket.function_bucket.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${var.project_id}@appspot.gserviceaccount.com"
}

# ------------------------------------------------------------------------------
# FIX FOR ERROR 13: Grant the "Builder Robot" access to the source code
# ------------------------------------------------------------------------------
resource "google_storage_bucket_iam_member" "cloud_build_reader" {
  bucket = google_storage_bucket.function_bucket.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${data.google_project.project.number}@cloudbuild.gserviceaccount.com"
}

resource "google_storage_bucket_iam_member" "function_bucket_reader" {
  bucket = google_storage_bucket.function_bucket.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

# NEW: Grant the Compute Robot access to ALL buckets (including the hidden gcf-sources)
resource "google_project_iam_member" "compute_storage_viewer" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

# 6. Deploy Cloud Function (Downgraded to Python 3.9 for Gen 1 stability)
resource "google_cloudfunctions_function" "visitor_counter" {
  name        = "visitor_counter"
  description = "Counts visitors"
  runtime     = "python39"          # <--- THIS IS THE FIX (was python310)
  region      = "us-west1"

  available_memory_mb   = 128
  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.zip_file.name
  trigger_http          = true
  entry_point           = "visitor_count"
  
  environment_variables = {
    PROJECT_ID = var.project_id
  }

  depends_on = [
    google_project_iam_member.compute_storage_viewer,
    google_project_service.cloud_functions,
    google_project_service.cloud_build,
    google_project_service.artifact_registry
  ]
}

# 7. Make Function Public
resource "google_cloudfunctions_function_iam_member" "invoker" {
  project        = google_cloudfunctions_function.visitor_counter.project
  region         = google_cloudfunctions_function.visitor_counter.region
  cloud_function = google_cloudfunctions_function.visitor_counter.name
  role           = "roles/cloudfunctions.invoker"
  member         = "allUsers"
}

# 8. Grant Function Database Access
resource "google_project_iam_member" "firestore_user" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${var.project_id}@appspot.gserviceaccount.com"
}

# ==============================================================================
# OUTPUTS
# ==============================================================================
output "website_ip_address" {
  value = google_compute_global_address.website_ip.address
  description = "The IP address to put in GoDaddy A-Record"
}

output "function_url" {
  value = google_cloudfunctions_function.visitor_counter.https_trigger_url
}