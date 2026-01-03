import functions_framework
from google.cloud import firestore

# Initialize the Database Client once
db = firestore.Client()

@functions_framework.http
def visitor_count(request):
    # ------------------------------------------------------------------
    # 1. CORS Headers (Security Handshake)
    # This allows your website (which is on the public internet) 
    # to talk to this specific backend function.
    # ------------------------------------------------------------------
    if request.method == 'OPTIONS':
        # Allows GET requests from any origin with the Content-Type header
        headers = {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET',
            'Access-Control-Allow-Headers': 'Content-Type',
            'Access-Control-Max-Age': '3600'
        }
        return ('', 204, headers)

    # Set CORS headers for the main request
    headers = {
        'Access-Control-Allow-Origin': '*'
    }

    # ------------------------------------------------------------------
    # 2. Database Logic
    # ------------------------------------------------------------------
    # Reference the document in the database
    doc_ref = db.collection('site_data').document('visitor_count')
    
    # Get the current count
    doc = doc_ref.get()
    
    if doc.exists:
        # If it exists, add 1 to the current count
        count = doc.to_dict().get('count', 0) + 1
        doc_ref.update({'count': count})
    else:
        # If this is the very first visitor, start at 1
        count = 1
        doc_ref.set({'count': count})
        
    # ------------------------------------------------------------------
    # 3. Return the Count
    # ------------------------------------------------------------------
    return (str(count), 200, headers)