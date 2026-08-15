import pandas as pd

df = pd.read_csv('raw_data/olist_order_reviews_dataset.csv')

print('--- Duplicate review_id ---')
dupes = df[df.duplicated('review_id', keep=False)]
print(f'{dupes.shape[0]} rows across {dupes["review_id"].nunique()} duplicated review_ids')

print()
print('--- Orders with multiple reviews ---')
multi = df.groupby('order_id').size()
multi = multi[multi > 1]
print(f'{len(multi)} orders have more than one review, out of {df["order_id"].nunique()} unique orders')
print(f'Max reviews on a single order: {multi.max() if len(multi) else 0}')

print()
print('--- Comment blank rates ---')
print(f'Blank titles:   {df["review_comment_title"].isna().sum()} / {len(df)} ({df["review_comment_title"].isna().mean():.1%})')
print(f'Blank messages: {df["review_comment_message"].isna().sum()} / {len(df)} ({df["review_comment_message"].isna().mean():.1%})')

print()
print('--- review_score distribution ---')
print(df['review_score'].value_counts().sort_index())

print()
print('--- Date range ---')
print('review_creation_date:', df['review_creation_date'].min(), 'to', df['review_creation_date'].max())
print('review_answer_timestamp:', df['review_answer_timestamp'].min(), 'to', df['review_answer_timestamp'].max())

print('--- Sample duplicate review_ids ---')
dup_ids = df[df.duplicated('review_id', keep=False)]['review_id'].unique()[:5]
for rid in dup_ids:
    print(df[df['review_id'] == rid][['review_id','order_id','review_score','review_creation_date','review_answer_timestamp']].to_string())
    print()

print('--- Are duplicate rows fully identical? ---')
full_dupes = df[df.duplicated(keep=False)]
print(f'{df.duplicated().sum()} fully-identical duplicate rows (all columns match)')

print()
print('--- Do all duplicate review_ids share identical score/dates but differ only on order_id? ---')
dup_review_ids = df[df.duplicated('review_id', keep=False)]['review_id'].unique()
check_cols = ['review_score', 'review_comment_title', 'review_comment_message', 'review_creation_date', 'review_answer_timestamp']

consistent = 0
inconsistent = 0
for rid in dup_review_ids:
    rows = df[df['review_id'] == rid]
    if rows[check_cols].nunique().max() == 1:
        consistent += 1
    else:
        inconsistent += 1

print(f'Consistent (only order_id differs): {consistent}')
print(f'Inconsistent (other fields differ too): {inconsistent}')