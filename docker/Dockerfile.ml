FROM shared-base:latest

RUN pip install --no-cache-dir sentence-transformers

# Pre-cache the embedding model at build time so container startup is instant
RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('all-MiniLM-L6-v2')"
