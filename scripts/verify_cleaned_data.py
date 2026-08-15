import pandas as pd

fact = pd.read_csv('cleaned_data/fact_reviews_clean.csv')
bridge = pd.read_csv('cleaned_data/bridge_review_order_clean.csv')
orders = pd.read_csv('cleaned_data/orders_delivery_clean.csv')

print('=== fact_reviews_clean ===')
print(fact.dtypes)
print(fact.head(5).to_string())
print()
print('review_score distribution:')
print(fact['review_score'].value_counts().sort_index())
print()
print('has_comment by score (sanity check — expect low scores to comment more):')
print(fact.groupby('review_score')['has_comment'].mean())

print()
print('=== bridge_review_order_clean ===')
print(bridge.dtypes)
print(bridge.head(5).to_string())
print(f"Unique review_ids in bridge: {bridge['review_id'].nunique()}")
print(f"Unique order_ids in bridge: {bridge['order_id'].nunique()}")

print()
print('=== orders_delivery_clean ===')
print(orders.dtypes)
print(orders.head(5).to_string())
print()
print('order_status distribution:')
print(orders['order_status'].value_counts())

print()
print('=== Review scores by order_status ===')
merged = bridge.merge(orders[['order_id', 'order_status']], on='order_id', how='left')
merged = merged.merge(fact[['review_id', 'review_score']], on='review_id', how='left')

print(merged.groupby('order_status')['review_score'].agg(['count', 'mean']))