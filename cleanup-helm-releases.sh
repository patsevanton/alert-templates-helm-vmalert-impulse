#!/usr/bin/env bash

set -euo pipefail

helm uninstall -n golden-signal-app	golden-signal-app	
helm uninstall -n impulse          	impulse          	
helm uninstall -n vmks             	vmks             	
