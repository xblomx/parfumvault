#!/bin/bash

# Get the directory of the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="/html"
DB_UPDATES_DIR="$PROJECT_ROOT/db/updates"
SCHEMA_VER_FILE="$PROJECT_ROOT/db/schema.ver"
ERROR_LOG="/tmp/dbupdate.err"

# Function to log errors
log_error() {
    local error_msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] ERROR: $error_msg" >> "$ERROR_LOG"
    echo "Error logged to $ERROR_LOG"
}

# Function to get current schema version from database
get_db_schema_version() {
    QUERY="SELECT schema_ver FROM pv_meta ORDER BY CAST(schema_ver AS UNSIGNED) DESC LIMIT 1;"
    RESULT=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "$QUERY" -s -N 2>"$ERROR_LOG")
    
    if [ $? -ne 0 ] || [ -z "$RESULT" ]; then
        # If pv_meta table doesn't exist or schema_ver is not set, assume version 0
        echo "0"
    else
        echo "$RESULT"
    fi
}

# Function to get target schema version from file
get_file_schema_version() {
    if [ -f "$SCHEMA_VER_FILE" ]; then
        cat "$SCHEMA_VER_FILE"
    else
        log_error "Schema version file not found at $SCHEMA_VER_FILE"
        echo "Error: Schema version file not found at $SCHEMA_VER_FILE"
        exit 1
    fi
}

# Function to update schema version in database
update_db_schema_version() {
    NEW_VERSION=$1
    QUERY="UPDATE pv_meta SET schema_ver='$NEW_VERSION';"
    
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "$QUERY" 2>>"$ERROR_LOG"
    if [ $? -eq 0 ]; then
        echo "Schema version updated to $NEW_VERSION"
    else
        log_error "Failed to update schema version to $NEW_VERSION"
        echo "Failed to update schema version"
        return 1
    fi
}

# Function to apply a single update file
apply_update_file() {
    UPDATE_FILE=$1
    VERSION=$2
    local errors=0
    local total_queries=0
    local failed_queries=()
    
    echo "Applying update file: $UPDATE_FILE (version $VERSION)"
    
    # Process the SQL file line by line to handle individual query errors
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        if [[ -z "$line" || "$line" =~ ^[[:space:]]*-- || "$line" =~ ^[[:space:]]*$ ]]; then
            continue
        fi
        
        # If line ends with semicolon, it's a complete query
        if [[ "$line" =~ \;[[:space:]]*$ ]]; then
            ((total_queries++))
            
            # Execute the query
            mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "$line" 2>>"$ERROR_LOG"
            if [ $? -ne 0 ]; then
                ((errors++))
                failed_queries+=("$line")
                log_error "Query failed in $UPDATE_FILE: $line"
            fi
        fi
    done < "$UPDATE_FILE"
    
    # Log summary
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] SUMMARY for $UPDATE_FILE (version $VERSION): $total_queries queries processed, $errors failed" >> "$ERROR_LOG"
    
    if [ $errors -gt 0 ]; then
        echo "[$timestamp] Failed queries:" >> "$ERROR_LOG"
        for query in "${failed_queries[@]}"; do
            echo "  - $query" >> "$ERROR_LOG"
        done
        echo "Warning: $errors out of $total_queries queries failed in version $VERSION. Check $ERROR_LOG for details."
    else
        echo "Successfully applied all queries for version $VERSION"
    fi
    
    # Always update schema version, even if some queries failed
    update_db_schema_version "$VERSION"
    return 0
}

# Function to apply all pending updates
apply_updates() {
    CURRENT_VERSION=$1
    TARGET_VERSION=$2
    
    if [ ! -d "$DB_UPDATES_DIR" ]; then
        echo "Error: Updates directory not found at $DB_UPDATES_DIR"
        exit 1
    fi
    
    # Get list of available update files and sort them by version number
    for update_file in "$DB_UPDATES_DIR"/update_*.sql; do
        if [ -f "$update_file" ]; then
            # Extract version from filename (e.g., update_14.1.sql -> 14.1)
            version=$(basename "$update_file" | sed 's/update_\(.*\)\.sql/\1/')
            
            # Check if this version is between current and target
            current_compare=$(version_compare "$version" "$CURRENT_VERSION")
            target_compare=$(version_compare "$version" "$TARGET_VERSION")
            
            if [ "$current_compare" -eq 1 ] && [ "$target_compare" -le 0 ]; then
                apply_update_file "$update_file" "$version"
                if [ $? -ne 0 ]; then
                    echo "Update process failed at version $version"
                    exit 1
                fi
            fi
        fi
    done
}

# Function to compare version numbers (supports decimal versions)
version_compare() {
    local version1=$1
    local version2=$2
    
    # Convert versions to comparable format by padding with zeros
    local v1=$(echo "$version1" | awk -F. '{printf "%d%03d", $1, $2}')
    local v2=$(echo "$version2" | awk -F. '{printf "%d%03d", $1, $2}')
    
    if [ "$v1" -eq "$v2" ]; then
        echo "0"  # Equal
    elif [ "$v1" -lt "$v2" ]; then
        echo "-1" # version1 < version2
    else
        echo "1"  # version1 > version2
    fi
}

# Main execution
DB_VERSION=$(get_db_schema_version)
FILE_VERSION=$(get_file_schema_version)

echo "Current database schema version: $DB_VERSION"
echo "Target schema version: $FILE_VERSION"

COMPARISON=$(version_compare "$DB_VERSION" "$FILE_VERSION")

if [ "$COMPARISON" -eq 0 ]; then
    echo "Database schema is up to date. No updates needed."
elif [ "$COMPARISON" -eq -1 ]; then
    echo "Database schema needs to be updated from version $DB_VERSION to $FILE_VERSION"
    apply_updates "$DB_VERSION" "$FILE_VERSION"
    echo "Schema update completed successfully."
else
    echo "Warning: Database schema version ($DB_VERSION) is higher than file version ($FILE_VERSION)"
    echo "This may indicate a rollback or version mismatch."
fi


