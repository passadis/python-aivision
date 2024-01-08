from flask import Flask, render_template, request, redirect, url_for, flash
from azure.storage.blob import BlobServiceClient
from azure.identity import DefaultAzureCredential
from werkzeug.utils import secure_filename
from azure.cognitiveservices.vision.face import FaceClient
from azure.cognitiveservices.vision.computervision import ComputerVisionClient
from azure.cognitiveservices.vision.computervision.models import VisualFeatureTypes
from msrest.authentication import CognitiveServicesCredentials
import requests
import os
import cv2
import io
import logging
import tempfile
import random
import numpy as np


app = Flask(__name__)
app.config['UPLOAD_EXTENSIONS'] = ['.mp4', '.mov', '.avi']
app.config['MAX_CONTENT_LENGTH'] = 50 * 1024 * 1024  # 50 MB
app.secret_key = '1q2w3e4r'
logging.basicConfig(filename='error.log', level=logging.ERROR)
computervision_client = ComputerVisionClient(os.getenv('COMPUTERVISION_ENDPOINT'), CognitiveServicesCredentials(os.getenv('COMPUTERVISION_KEY')))
blob_service_client = BlobServiceClient(account_url=os.getenv('AZURE_ACCOUNT_URL'), credential=DefaultAzureCredential())
vision_api_endpoint = os.getenv('COMPUTERVISION_ENDPOINT')
vision_api_key = os.getenv('COMPUTERVISION_KEY')
vision_client = ComputerVisionClient(vision_api_endpoint, CognitiveServicesCredentials('COMPUTERVISION_KEY'))

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/upload')
def upload():
    return render_template('upload.html')

@app.route('/upload', methods=['POST'])
def upload_file():
    file = request.files['file']
    if file:
        filename_with_ext = secure_filename(file.filename)
        filename, file_ext = os.path.splitext(filename_with_ext)
        
        if file_ext not in app.config['UPLOAD_EXTENSIONS']:
            flash('Invalid file type!')
            return redirect(url_for('upload'))
        
        # Save the file temporarily
        temp_path = os.path.join(tempfile.gettempdir(), filename_with_ext)  # Use filename with extension for temp save
        file.save(temp_path)

        container_client = blob_service_client.get_container_client(os.getenv('AZURE_CONTAINER_NAME'))
        blob_client = container_client.get_blob_client(filename_with_ext)
        
        try:
            # Save video to Blob Storage
            with open(temp_path, 'rb') as f:
                blob_client.upload_blob(f, overwrite=True)
            
            # Open the video file from temporary location
            cap = cv2.VideoCapture(temp_path)
            fps = int(cap.get(cv2.CAP_PROP_FPS))
            frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    
            # Set the time interval (in seconds)
            time_interval = 5
    
            # Calculate the total number of intervals
            num_intervals = frame_count // (fps * time_interval)
            # Loop through each interval and save the corresponding frame
            for i in range(num_intervals + 1):  # +1 to include the last frame
                frame_number = i * time_interval * fps
                cap.set(cv2.CAP_PROP_POS_FRAMES, frame_number)
                ret, frame = cap.read()
            
                if ret:
                    _, buffer = cv2.imencode('.jpg', frame)
                    img_byte_io = io.BytesIO(buffer)
            
                    frame_blob_name = f"{filename}/frame_{frame_number}.jpg"
                    frame_blob_client = container_client.get_blob_client(frame_blob_name)
            
                    frame_blob_client.upload_blob(img_byte_io, overwrite=True)
            
            cap.release()
            os.remove(temp_path)  # Remove the temporary file once done
            
            flash('File and frames uploaded successfully')  
        except Exception as e:        
            flash(f'An error occurred: {e}')
            return redirect(url_for('upload'))

        return redirect(url_for('upload'))

    flash('No file uploaded')
    return redirect(url_for('upload'))
def get_video_urls():
    container_client = blob_service_client.get_container_client(os.getenv('AZURE_CONTAINER_NAME'))
    blob_list = container_client.list_blobs()

    # Only fetch .mp4 files
    video_urls = [container_client.get_blob_client(blob.name).url for blob in blob_list if blob.name.endswith('.mp4')]
    return video_urls

@app.route('/browse')
def browse():
    video_urls = get_video_urls()
    return render_template('browse.html', video_urls=video_urls)

@app.route('/analyze', methods=['POST'])
def analyze_video():
    video_url = request.form.get('video_url')
    video_basename = os.path.basename(video_url).split('.')[0]

    container_client = blob_service_client.get_container_client(os.getenv('AZURE_CONTAINER_NAME'))
    blob_list = list(container_client.list_blobs(name_starts_with=video_basename))

    if not blob_list:
        flash('No frames found for the video.')
        return redirect(url_for('browse'))

    random_frame_blob = random.choice(blob_list)
    frame_blob_client = container_client.get_blob_client(random_frame_blob.name)
    frame_bytes = io.BytesIO(frame_blob_client.download_blob().readall())
    img_arr = np.frombuffer(frame_bytes.getvalue(), dtype=np.uint8)
    img = cv2.imdecode(img_arr, cv2.IMREAD_COLOR)

    analysis = computervision_client.analyze_image_in_stream(frame_bytes, visual_features=[VisualFeatureTypes.objects])

    detected_objects = []
    for detected_object in analysis.objects:
        # Draw bounding boxes around detected objects
        left = detected_object.rectangle.x
        top = detected_object.rectangle.y
        right = left + detected_object.rectangle.w
        bottom = top + detected_object.rectangle.h
        label = detected_object.object_property
        confidence = detected_object.confidence

        # Draw rectangle and label
        color = (255, 0, 0)
        cv2.rectangle(img, (left, top), (right, bottom), color, 2)
        font = cv2.FONT_HERSHEY_SIMPLEX
        label_size = cv2.getTextSize(label, font, 0.5, 2)[0]
        cv2.rectangle(img, (left, top - label_size[1] - 10), (left + label_size[0], top), color, -1)
        cv2.putText(img, f"{label} ({confidence:.2f})", (left, top - 5), font, 0.5, (255, 255, 255), 2)

        detected_objects.append({
            'label': label,
            'confidence': confidence
        })

    # Convert image back to bytes to store in blob storage
    _, buffer = cv2.imencode('.jpg', img)
    img_byte_io = io.BytesIO(buffer)

    # Upload the result image to the Blob storage
    result_blob_name = f"{video_basename}/analyzed_frame.jpg"
    result_blob_client = container_client.get_blob_client(result_blob_name)
    result_blob_client.upload_blob(img_byte_io, overwrite=True)
    video_urls = get_video_urls()
    # Send analysis results to the template
    analysis_results = {
    'analyzed_video_url': video_url,  # The URL of the video that was analyzed
    'img_url': result_blob_client.url,  # The URL of the analyzed frame
    'objects': detected_objects  # Detected objects and their details
    }
  
    return render_template('browse.html', video_urls=video_urls, analysis_results=analysis_results)


if __name__ == '__main__':
    app.run(debug=True)

