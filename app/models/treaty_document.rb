class TreatyDocument < ActiveRecord::Base

  MAXIMUM_NUMBER_OF_DOCUMENTS = 25
 
  named_scope :by_category, lambda{|category| {:conditions=>["category=?",category]}}
  named_scope :by_negotiation_status, lambda{|negotiation_status| {:conditions=>["negotiation_status=?",negotiation_status]}}
  named_scope :latest_three, :limit=>3, :order=>"date DESC"

  named_scope :since, lambda{|time| {:conditions=>["date>?",time]}}

  acts_as_taggable_on :issues

  NEGOTIATION_STAGES = [
                     {:id=>0, :name=>"Umsóknarferli"},
                     {:id=>1, :name=>"Ríkjaráðstefna"},
                     {:id=>2, :name=>"Rýnivinna"},
                     {:id=>3, :name=>"Viðmið fyrir opnun kafla"},
                     {:id=>4, :name=>"Samningsafstaða Íslands"},
                     {:id=>5, :name=>"Samningsafstaða ESB"},
                     {:id=>6, :name=>"Opnun kafla"},
                     {:id=>7, :name=>"Viðmið fyrir lokun kafla"},
                     {:id=>8, :name=>"Aðildarsamningur"}
          ]
  
  def tag_name
    if self.chapter==36
      "Allir kaflar"
    else
      self.cached_issue_list
    end
  end
end
