variable "project_id" {
  description = "The ID of the Google Cloud project"
  type        = string
  default     = "dimarc-www-prod" 
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
  project = "dimarc-www-prod"
  region  = "us-west1"
}

# 2. Create the Bucket for the Website
resource "google_storage_bucket" "website" {
  name          = "dimarc-www-prod-bucket"  # This must be globally unique
  location      = "US"
  uniform_bucket_level_access = true
  
  # Ensure we serve index.html when people visit
  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }

  # Force destroy allows us to delete the bucket even if it has files in it
  force_destroy = true
}

# 3. Make the Bucket Public (So people can see the site)
resource "google_storage_bucket_iam_member" "public_rule" {
  bucket = google_storage_bucket.website.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# --------------------------------------------------------------------------------
# BACKEND INFRASTRUCTURE
# --------------------------------------------------------------------------------

# 1. Enable the Services automatically
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

# 2. Create the Firestore Database
resource "google_firestore_database" "database" {
  name        = "(default)"
  location_id = "us-central1"
  type        = "FIRESTORE_NATIVE"

  depends_on = [google_project_service.firestore]
}

# --------------------------------------------------------------------------------
# CLOUD FUNCTION (THE BRAIN)
# --------------------------------------------------------------------------------

# 1. Create a Bucket to store the Python Code (Private)
resource "google_storage_bucket" "function_bucket" {
  name                        = "${var.project_id}-function-source" # Unique name
  location                    = "US"
  uniform_bucket_level_access = true
}

# 2. Zip the 'api' folder into a single file
data "archive_file" "source_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../api"
  output_path = "${path.module}/function.zip"
}

# 3. Upload the Zip file to the Bucket
resource "google_storage_bucket_object" "zip_file" {
  name   = "source-${data.archive_file.source_zip.output_md5}.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = data.archive_file.source_zip.output_path
}

# --------------------------------------------------------------------------------
# SECURITY SCRUB: Least Privilege Access
# --------------------------------------------------------------------------------

# 1. Get Project Details (To find the robot's email)
data "google_project" "project" {
}

# 2. Grant the Robot access ONLY to the specific function source bucket
resource "google_storage_bucket_iam_member" "function_bucket_reader" {
  bucket = google_storage_bucket.function_bucket.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

# 4. Deploy the Cloud Function
resource "google_cloudfunctions_function" "visitor_counter" {
  name        = "visitor_counter"
  description = "Counts visitors and returns the total"
  runtime     = "python310"

  available_memory_mb   = 128
  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.zip_file.name
  trigger_http          = true
  entry_point           = "visitor_count" # The function name in main.py
  
  environment_variables = {
    PROJECT_ID = var.project_id
  }
}

# 5. Make the Function Public (So your website can call it)
resource "google_cloudfunctions_function_iam_member" "invoker" {
  project        = google_cloudfunctions_function.visitor_counter.project
  region         = google_cloudfunctions_function.visitor_counter.region
  cloud_function = google_cloudfunctions_function.visitor_counter.name

  role   = "roles/cloudfunctions.invoker"
  member = "allUsers"
}

# --------------------------------------------------------------------------------
# OUTPUTS (The Information You Need)
# --------------------------------------------------------------------------------
output "function_url" {
  value = google_cloudfunctions_function.visitor_counter.https_trigger_url
}

# 3. FIX FOR CORS/CRASH: Give the Cloud Function permission to write to the Database
resource "google_project_iam_member" "firestore_user" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${var.project_id}@appspot.gserviceaccount.com"
}