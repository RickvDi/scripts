#!/bin/bash
#This is the Gunicorn script used to automatically launch the application through Gunicorn
NAME="django-application"

#path to the folder containing the manage.py file
DIR=/home/rick/volgsysteem/volgsysteem/volgsysteem_au/

# Replace with your system user
USER=rick
# Replace with your system group
GROUP=rick

WORKERS=3

#bind to port 8000
BIND=127.0.0.1:8000

# Put your project name
DJANGO_SETTINGS_MODULE=volgsysteem_au.settings
DJANGO_WSGI_MODULE=volgsysteem_au.wsgi

LOG_LEVEL=error

cd $DIR

#activating the virtual environment
source /home/rick/volgsysteem/volgsysteem/volgsysteem_au/env/bin/activate

export DJANGO_SETTINGS_MODULE=$DJANGO_SETTINGS_MODULE

export PYTHONPATH=$DIR:$PYTHONPATH

exec gunicorn ${DJANGO_WSGI_MODULE}:application \

  --name $NAME \

  --workers $WORKERS \

  --user=$USER \

  --group=$GROUP \

  --bind=$BIND \

  --log-level=$LOG_LEVEL \

  --log-file=-
