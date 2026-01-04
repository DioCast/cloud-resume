// js/main.js

// Ideally, this URL is injected via a config file during the CI/CD build, 
// but for a static site, defining it at the top is acceptable.
const FUNCTION_API_URL = "https://us-west1-dio-castillo-cloud.cloudfunctions.net/visitor_counter";

const getVisitCount = async () => {
    try {
        const response = await fetch(FUNCTION_API_URL);
        const count = await response.text();
        
        console.log("Visitor count fetched:", count);
        
        const counterElement = document.getElementById("counter");
        if (counterElement) {
            counterElement.innerText = count;
        }
    } catch (error) {
        console.error("Failed to fetch visitor count:", error);
    }
};

// Use 'defer' in the HTML script tag so you don't need DOMContentLoaded listeners
getVisitCount();