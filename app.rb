require 'csv'
require 'set'
require 'gender_detector'

def assign_rejection_reason(assignment_ids, reason)
  assignment_map = {}
  assignment_ids.each { |id| assignment_map[id] = [reason] }
  assignment_map
end

def merge_rejections(rejections, new_rejections)
  new_rejections.each do |id, reasons|
    rejections[id] ||= []
    rejections[id].push(*reasons)
  end
end

# HITs that said that they couldn't find teacher at a school when others were
# able to
def assignments_that_should_have_found_email(hits)
  found_schools = {}
  bad_assignments = Set.new

  hits.each do |id, hit|
    if found_schools["#{hit[:school]} #{hit[:region]}"].nil? && hit[:found_teacher] == 'yes'
      found_schools["#{hit[:school]} #{hit[:region]}"] = true
    end
  end

  hits.each do |id, hit|
    if found_schools["#{hit[:school]} #{hit[:region]}"] && hit[:found_teacher] == 'no'
      bad_assignments << id
    end
  end

  bad_assignments
end

# HITs that gave invalid emails
def assignments_with_invalid_email(hits)
  email_regex = /\A[\w+\-.]+@[a-z\d\-.]+\.[a-z]+\z/i
  bad_assignments = Set.new

  hits.each do |id, hit|
    if hit[:found_teacher] == 'yes' && !email_regex.match(hit[:teacher][:email])
      bad_assignments << id
    end
  end

  bad_assignments
end

# Assignments that should have found a last name
def assignments_without_last_name(assignments)
  bad_assignments = Set.new

  assignments.each do |id, assignment|
    if assignment[:found_teacher] == 'yes' && assignment[:teacher][:last_name] == '{}'
      bad_assignments << id
    end
  end

  bad_assignments
end

# Downcase emails
def downcase_emails_of(schools)
  new_schools = {}

  schools.each do |name, teachers_list|
    new_teachers_list = []

    teachers_list.each do |teacher|
      new_teacher = teacher.clone
      new_teacher[:email] = new_teacher[:email].downcase

      new_teachers_list << new_teacher
    end

    new_schools[name] = new_teachers_list
  end

  new_schools
end

def dedup_teachers_of(schools)
  new_schools = {}

  schools.each do |name, teachers_list|
    new_teachers_list = []

    teachers_list.each do |teacher|
      new_teacher_names = new_teachers_list.map { |t| "#{t[:first_name]} #{t[:last_name]}" }
      new_teacher_emails = new_teachers_list.map { |t| t[:email] }

      unless new_teacher_names.include? "#{teacher[:first_name]} #{teacher[:last_name]}" or
            new_teacher_emails.include? teacher[:email]
        new_teachers_list << teacher
      end
    end

    new_schools[name] = new_teachers_list
  end

  new_schools
end

def fix_teacher_info_in(schools)
  gd = GenderDetector.new

  new_schools = {}

  schools.each do |name, teachers|
    new_teachers = []

    teachers.each do |t|
      nt = t.clone

      if nt[:first_name] == nt[:first_name].upcase or
         nt[:first_name] == nt[:first_name].downcase
        nt[:first_name] = nt[:first_name].downcase.capitalize
      end

      if nt[:last_name] == nt[:last_name].upcase or
        nt[:last_name] == nt[:last_name].downcase
        nt[:last_name] = nt[:last_name].downcase.capitalize
      end

      if nt[:first_name] == '{}'
        nt[:first_name] = '(First)'
      end

      if nt[:subject] == '{}'
        nt[:subject] = 'Unspecified'
      end

      if ['{}', 'not_found'].include? nt[:title]
        case gd.get_gender(nt[:first_name])
        when :male, :mostly_male
          nt[:title] = 'Mr.'
        when :female, :mostly_female
          nt[:title] = 'Ms.'
        end
      end

      new_teachers << nt
    end

    new_schools[name] = new_teachers
  end

  new_schools
end

def write_schools_csv(path, schools, divider)
  rows = ['School', 'Region', 'Name', 'Email', 'Subject', 'Title', 'URL', 'Notes']

  CSV.open(path, 'w') do |csv|
    csv << rows

    schools.each do |school, teachers|
      school_name, school_region = school.split(divider)

      teachers.each do |teacher|
        csv << [
          school_name,
          school_region,
          "#{teacher[:first_name]} #{teacher[:last_name]}",
          teacher[:email],
          teacher[:subject],
          teacher[:title],
          teacher[:url],
          school_name + ' | ' + school_region
        ]
      end
    end
  end
end

def write_csv_for_mturk(path, all_assignments, approved_assignments, rejected_assignments)
  rows = ['AssignmentId', 'HITId', 'Approve', 'Reject', 'Rejection Reason']

  CSV.open(path, 'w') do |csv|
    csv << rows

    approved_assignments.each do |id|
      assignment = all_assignments[id]

      csv << [id, assignment[:hit_id], 'x', '', '']
    end

    rejected_assignments.each do |id, reasons|
      assignment = all_assignments[id]
      reason = reasons.join(', ').capitalize

      csv << [id, assignment[:hit_id], '', 'x', reason]
    end
  end
end

assignments = {}
assignments_to_approve = Set.new
assignments_to_reject = {}

is_header = true
CSV.foreach('batch.csv', :encoding => 'ISO-8859-1') do |row|
  # Skip header row
  if is_header
    is_header = false
    next
  end

  assignment_id = row[14]

  assignments[assignment_id] = {
    hit_id: row[0],
    worker_id: row[15],
    school: row[27],
    region: row[28],
    found_teacher: row[30],
    teacher: {
      email: row[31],
      first_name: row[32],
      last_name: row[33],
      subject: row[34],
      title: row[35],
      url: row[36]
    }
  }
end

merge_rejections(assignments_to_reject, assign_rejection_reason(assignments_that_should_have_found_email(assignments), "other turkers were able to find a teacher email"))
merge_rejections(assignments_to_reject, assign_rejection_reason(assignments_with_invalid_email(assignments), "provided email was incorrectly formatted"))
merge_rejections(assignments_to_reject, assign_rejection_reason(assignments_without_last_name(assignments), "given teacher was missing a last name"))

assignments_to_approve = Set.new(assignments.keys) - assignments_to_reject.keys

divider = ' | '
schools = {}

assignments_to_approve.each do |assignment_id|
  assignment = assignments[assignment_id]

  if assignment[:found_teacher] == 'yes'
    schools[assignment[:school] + divider + assignment[:region]] ||= []
    schools[assignment[:school] + divider + assignment[:region]] << assignment[:teacher]
  end
end

schools = downcase_emails_of(schools)
schools = dedup_teachers_of(schools)
schools = fix_teacher_info_in(schools)

write_schools_csv('processed_teacher_emails.csv', schools, divider)
write_csv_for_mturk('decisions.csv', assignments, assignments_to_approve, assignments_to_reject)
