import json
import boto3

# Initialize the DynamoDB resource
dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('cloud-resume-stats')

def lambda_handler(event, context):
    # 1. Update the item in DynamoDB
    response = table.update_item(
        Key={'id': 'visitors'},
        UpdateExpression='ADD #c :val',
        ExpressionAttributeNames={'#c': 'count'},
        ExpressionAttributeValues={':val': 1},
        ReturnValues='UPDATED_NEW'
    )
    
    # 2. Get the new count from the response
    new_count = str(response['Attributes']['count'])
    
    # 3. Return the result with CORS headers (so your website can talk to it)
    return {
        'statusCode': 200,
        'headers': {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET'
        },
        'body': json.dumps({'count': new_count})
    }