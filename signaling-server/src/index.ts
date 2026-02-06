import dotenv from 'dotenv';

// Load environment variables
dotenv.config();

import { startServer } from './server';

// Start the signaling server
startServer();
