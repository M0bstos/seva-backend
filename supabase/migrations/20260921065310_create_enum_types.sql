create type category as enum (
  'environment', 'animals', 'community', 'education', 'health', 'other'
);

create type content_status as enum ('pending', 'visible', 'held', 'removed');

create type media_status as enum (
  'uploading', 'processing', 'ready', 'held', 'rejected'
);

create type media_purpose as enum ('act', 'activity', 'avatar');

create type metric as enum (
  'waste_kg', 'trees_planted', 'volunteer_hours', 'animals_helped', 'people_reached'
);

create type ledger_kind as enum ('act_published', 'activity_documented', 'metric');

create type account_status as enum ('active', 'suspended');

create type org_type as enum (
  'ngo', 'school', 'college', 'resident_association', 'company',
  'government_body', 'other'
);

create type staff_role as enum ('moderator', 'admin');

create type participant_status as enum ('joined', 'left');

create type report_subject as enum ('act', 'activity', 'profile');

create type report_reason as enum (
  'spam', 'inappropriate', 'unsafe', 'misleading', 'harassment',
  'intimate_imagery', 'impersonation', 'other'
);

create type report_status as enum ('open', 'actioned', 'dismissed');

create type guardian_consent as enum ('not_required', 'pending', 'granted');

create type campaign_goal as enum (
  'acts', 'waste_kg', 'trees_planted', 'volunteer_hours', 'animals_helped',
  'people_reached'
);

create type campaign_status as enum ('draft', 'active', 'ended');

create type audit_actor as enum ('staff', 'system');

create type app_flag as enum (
  'uploads', 'create_acts', 'create_activities', 'joins', 'award_points',
  'read_only'
);

create type deletion_status as enum ('pending', 'completed', 'failed');

create type export_status as enum ('pending', 'ready', 'failed', 'expired');
