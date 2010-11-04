class ReactionsController < ApplicationController

  def new
  end

  # POST /reactions
  def create
    @reaction = current_user.reactions.build(params[:reaction])

    respond_to do |format|
      if @reaction.save
        format.js { render('new') }
      else
        format.js { render('create_unsuccessful') }
      end
    end
  end

  # PUT /reactions/1
  def update
    @reaction = current_user.reactions.find(params[:id])

    # If reaction is being un-endorsed or un-opposed, destroy it
    if (@reaction.like? and "#{params[:reaction][:like]}" == "1") or (@reaction.dislike? and "#{params[:reaction][:dislike]}" == "1")
      @old_reaction = @reaction.clone
      # Remove the reaction
      @reaction.destroy
      @reaction = current_user.reactions.build({:priority => @old_reaction.priority})
      # Render
      respond_to do |format|
        format.js { render('new') }
      end
    # Otherwise, go ahead and update
    else
      respond_to do |format|
        if @reaction.update_attributes(params[:reaction])
          format.js { render('new') }
        end
      end
    end
  end
end
